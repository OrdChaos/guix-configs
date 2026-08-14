;;; TPM2 enrollment 工具（PCR7-only）：把独立随机 LUKS credential
;;; 密封到当前 PCR7，并把 credential 加入独立 LUKS keyslot。
;;;
;;; 用法（从仓库根目录，目标系统上以 root 运行）：
;;;   guix repl tools/tpm2-enroll.scm -- preflight
;;;   guix repl tools/tpm2-enroll.scm -- enroll          # 首次 enrollment
;;;   guix repl tools/tpm2-enroll.scm -- replace         # 显式重新 enrollment
;;;   guix repl tools/tpm2-enroll.scm -- status
;;;
;;; 职责边界：本工具是唯一允许修改机器 TPM/LUKS enrollment 的入口
;;; （luksAddKey / sealed object 创建 / credential 生成 / 状态推进）。
;;; 普通 `guix system reconfigure` 不调用本工具、不修改 enrollment——
;;; PCR7 不随 UKI 更新，enrollment 是独立机器状态。
;;;
;;; enrollment 流程（crash-safe 顺序）：
;;;   读取用户 recovery LUKS 密码并验证（--test-passphrase）
;;;   → 生成随机 TPM credential（32 字节 /dev/urandom，hex，仅内存）
;;;   → 读当前 PCR7（sha256:7）→ trial PolicyPCR digest
;;;   → createprimary + create sealed object（stdin 传 secret）
;;;   → 立即用当前 PCR7 验证 unseal
;;;   → cryptsetup luksAddKey 加入独立 keyslot（credential 经 stdin；
;;;     用户密码短暂落在 0600 临时文件——cryptsetup --key-file=-
;;;     是读到 EOF 的语义，无法与 --new-keyfile=- 共享 stdin，实测）
;;;   → 验证新 keyslot 可解锁
;;;   → 发布 ESP artifact（/efi/EFI/Guix/tpm2/，解锁前可读）
;;;     ——失败则 luksKillSlot 回滚刚加入的 keyslot
;;;   → 发布 /persist 管理副本 + 原子写 state.scm
;;;   → replace 模式最后才删旧 keyslot（用户 recovery keyslot 永不碰）

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg security tpm2 tpm2-tools)
             (guixcfg security tpm2 state)
             (guixcfg storage model)     ; %system-partlabel
             (guixcfg utils process)
             (guix build utils)         ; mkdir-p、invoke、file-writable?
             (ice-9 format)
             (ice-9 match)
             (ice-9 ftw)                ; scandir
             (ice-9 rdelim)             ; read-line
             (ice-9 regex)              ; string-match
             (ice-9 binary-ports)       ; get-bytevector-all/n!
             (ice-9 popen)              ; open-pipe*
             (rnrs bytevectors)         ; make-bytevector
             (srfi srfi-1)              ; filter-map、count
             (srfi srfi-13))            ; string-tokenize

;;; ────────────────────────────────────────────────────────────
;;; 工具定位与环境

(define (store-glob prefix subpath)
  "在 /gnu/store 顶层找 PREFIX 开头的条目，拼 SUBPATH 返回。
scandir 只列顶层条目名，不能把 /bin 等子路径写进匹配模式。"
  (let ((m (scandir "/gnu/store"
                    (lambda (name) (string-prefix? prefix name)))))
    (and (pair? m) (string-append "/gnu/store/" (car m) subpath))))

(define %tpm2-bin (or (getenv "GUIXCFG_TPM2_BIN")
                      (store-glob "tpm2-tools-" "/bin")
                      "/run/current-system/profile/bin"))
(define %cryptsetup (or (store-glob "cryptsetup-" "/sbin/cryptsetup")
                        "/run/current-system/profile/sbin/cryptsetup"))

;; 生产 /dev/tpmrm0；测试可用 GUIXCFG_TPM_TCTI 显式覆盖（如
;; "swtpm:path=..."）——绝不默默回退 swtpm。
(define %tcti (or (getenv "GUIXCFG_TPM_TCTI") "device:/dev/tpmrm0"))

;; ESP 挂载点（GUIXCFG_ESP 供测试覆盖）。
(define %esp (or (getenv "GUIXCFG_ESP") "/efi"))

;; ESP 侧 artifact 目录（initrd 解锁前读取）。
(define %esp-tpm2-dir (string-append %esp "/EFI/Guix/tpm2"))

;;; ────────────────────────────────────────────────────────────
;;; 环境检查（从 d832ef4 恢复，去掉 PolicyAuthorize 部分）

(define (recovery-boot?)
  "当前是否 Recovery 启动（/proc/cmdline rootmode=recovery）。"
  (let ((line (call-with-input-file "/proc/cmdline"
                                    (lambda (p) (read-line p)))))
    (let loop ((args (string-tokenize line)))
      (cond ((null? args) #f)
        ((string-prefix? "rootmode=recovery" (car args)) #t)
        (else (loop (cdr args)))))))

(define (secure-boot-enabled?)
  "读取 EFI SecureBoot / SetupMode 变量（efivarfs）。SecureBoot==1 且
SetupMode==0 才认为 Secure Boot 已启用；无法读取返回 #f
（无法可靠证明时拒绝首次 enrollment，不在 Secure Boot disabled
状态批准 PCR7）。"
  (define (efi-var-value name)
    (let ((path (string-append "/sys/firmware/efi/efivars/"
                               name "-8be4df61-93ca-11d2-aa0d-00e098032b8c")))
      (and (file-exists? path)
           (let ((bv (call-with-input-file path
                                           (lambda (p)
                                             (get-bytevector-all p)))))
             ;; 4 字节 attributes + 1 字节 value
             (and (>= (bytevector-length bv) 5)
                  (bytevector-u8-ref bv 4))))))
  (let ((sb (efi-var-value "SecureBoot"))
        (sm (efi-var-value "SetupMode")))
    (and sb sm (= sb 1) (= sm 0))))

(define (luks-device)
  "LUKS 设备路径。完整系统有 udev，PARTLABEL 链接可用。"
  (string-append "/dev/disk/by-partlabel/" %system-partlabel))

(define (luks-is-luks2?)
  (zero? (system* %cryptsetup "isLuks" (luks-device))))

(define (read-passphrase! prompt)
  "关闭终端回显读取密码；stdin 非 tty（SSH 管道/测试）时直读。"
  (display prompt)
  (force-output)
  (let ((pw (if (isatty? (current-input-port))
              (dynamic-wind
               (lambda () (invoke "stty" "-echo"))
               (lambda () (read-line))
               (lambda () (invoke "stty" "echo")))
              (read-line))))
    (newline)
    pw))

(define (luks-passphrase-valid? passphrase)
  (catch #t
    (lambda ()
      (invoke-with-stdin passphrase %cryptsetup
                         "open" "--test-passphrase" (luks-device))
      #t)
    (lambda (key . args) #f)))

(define (luks-max-keyslot)
  "luksDump 中最大的 keyslot 编号（新加的 slot = 最大编号）。
cryptsetup 2.8 的 luksDump 输出是 '  N: luks2'（无 'Keyslot' 前缀，
T3 实测）；旧格式 'Keyslot N:' 也兼容。"
  (let* ((dump (invoke-capture %cryptsetup "luksDump" (luks-device)))
         (slots (filter-map (lambda (line)
                              (let ((m (or (string-match "^Keyslot ([0-9]+):" line)
                                           (string-match
                                            "^[[:space:]]*([0-9]+): luks" line))))
                                (and m (string->number (match:substring m 1)))))
                            (string-split dump #\newline))))
    (and (pair? slots) (apply max slots))))

(define (random-credential)
  "32 字节 /dev/urandom → 64 位 hex 字符串（LUKS keyslot passphrase）。
只存在于内存、TPM sealed object 与 LUKS keyslot。"
  (let ((bv (make-bytevector 32 0)))
    (call-with-input-file "/dev/urandom"
                          (lambda (p) (get-bytevector-n! p bv 0 32)))
    (bytes->hex bv)))

(define (tpmrm0-present?)
  "TPM 设备可用（生产 TCTI 时检查 /dev/tpmrm0；显式测试 TCTI 跳过）。"
  (or (getenv "GUIXCFG_TPM_TCTI")
      (file-exists? "/dev/tpmrm0")))

;;; ────────────────────────────────────────────────────────────
;;; preflight

(define (dir-writable? path)
  "写权限检查（不依赖 (ice-9 posix)——guix 的 guile 环境加载不了该
模块，实测；stat mode 的 owner/group/other 写位任一即可）。"
  (and (file-exists? path)
       (let ((st (stat path)))
         (not (zero? (logand (stat:mode st) #o222))))))

(define (preflight)
  (define (check name ok?)
    (format #t "  [~a] ~a~%" (if ok? "ok" "FAIL") name)
    ok?)
  (format #t "== TPM2 enrollment preflight ==~%")
  (let* ((results
          (list
           (check "TPM2 设备可用"
                  (tpmrm0-present?))
           (check "当前系统不是 Recovery"
                  (not (recovery-boot?)))
           (check "目标设备是 LUKS2"
                  (and (file-exists? (luks-device)) (luks-is-luks2?)))
           (check "Secure Boot 已启用（SecureBoot==1 且非 SetupMode）"
                  (secure-boot-enabled?))
           (check "ESP 已挂载（/efi/EFI/Guix 存在）"
                  (file-exists? "/efi/EFI/Guix"))
           (check "/persist 可写"
                  (dir-writable? "/persist/system"))))
         (fail-count (count (lambda (x) (not x)) results)))
    (format #t "preflight: ~a 项失败~%" fail-count)
    (exit (if (zero? fail-count) 0 1))))

;;; ────────────────────────────────────────────────────────────
;;; enrollment 主体（enroll / replace 共用）

(define* (do-enroll #:key (replace? #f) (passphrase #f))
         "执行 enrollment（enroll / replace 共用主体）。PASSPHRASE 为 #f 时
交互读取（do-replace 传入以复用一次密码输入）。
所有明文临时材料只存在于 /run/guixcfg/tpm2-enroll/（tmpfs、root-only、
unique 目录）；dynamic-wind 保证正常与异常路径都清理。"
         (define id (string-append "enroll-" (number->string (current-time))))
         (define workdir (string-append "/run/guixcfg/tpm2-enroll/" id))
         
         ;; ── 硬性前置检查（任一不满足即中止，不做任何修改）────────
         (unless (tpmrm0-present?) (error "TPM2 设备不可用"))
         (when (recovery-boot?) (error "Recovery 模式禁止 enrollment"))
         (unless (and (file-exists? (luks-device)) (luks-is-luks2?))
           (error "目标不是 LUKS2"))
         (unless (secure-boot-enabled?)
           (error "Secure Boot 未启用/无法证明启用；拒绝 TPM enrollment"))
         (unless (file-exists? "/efi/EFI/Guix")
           (error "ESP 未挂载或布局缺失（/efi/EFI/Guix）"))
         (let ((existing (read-tpm2-state)))
           (when (and (tpm2-enrolled? existing) (not replace?))
             (error "已 enrollment（~a）。如需重新 enrollment 请用 replace 命令"
                    (tpm2-enrollment-id existing))))
         
         (dynamic-wind
          (lambda () #t)
          (lambda ()
            (format #t "DBG0 pre-workdir~%")
            (mkdir-p workdir)
            
            ;; 1. 用户 recovery 密码：验证实际有效（luksAddKey 的授权凭据）
            (let ((passphrase (or passphrase
                                  (read-passphrase! "输入 recovery LUKS 密码: "))))
              (format #t "DBG1 passphrase~%")
              (unless (luks-passphrase-valid? passphrase)
                (error "recovery 密码无法解锁 LUKS；中止"))
              (format #t "recovery 密码验证通过。~%")
              
              ;; 2. 显示当前 PCR7 并确认（Secure Boot 已启用状态下的机器 policy）
              (format #t "DBG2 pcrread~%")
              (let* ((pcr7-hex (tpm2-pcrread! %tcti %tpm2-bin "sha256:7"))
                     (pcr7-file (string-append workdir "/pcr7.bin")))
                (format #t "当前 PCR7 = ~a~%" pcr7-hex)
                (format #t "确认在 Secure Boot 已启用的状态下执行 enrollment？输入 yes: ")
                (force-output)
                (unless (string-ci=? (read-line) "yes")
                  (error "未确认；中止 enrollment"))
                
                ;; 3. 随机 credential + sealed object
                (let* ((credential (random-credential))
                       (policy-file (string-append workdir "/policy.pcr.digest"))
                       (primary (string-append workdir "/primary.ctx"))
                       (seal-pub (string-append workdir "/seal.pub"))
                       (seal-priv (string-append workdir "/seal.priv"))
                       (seal-ctx (string-append workdir "/seal.ctx")))
                  ;; trial PolicyPCR（期望值 = 当前 PCR7）
                  (tpm2-pcrread! %tcti %tpm2-bin "sha256:7" #:out pcr7-file)
                  (format #t "DBG3 sealed~%")
                  (tpm2-policy-pcr-digest! %tcti %tpm2-bin pcr7-file
                                           #:pcr "sha256:7" #:out policy-file)
                  (tpm2-createprimary! %tcti %tpm2-bin #:out primary)
                  (tpm2-create-sealed! %tcti %tpm2-bin primary policy-file
                                       credential
                                       #:public-out seal-pub #:private-out seal-priv)
                  (format #t "sealed object 已创建（credential 仅内存）~%")
                  
                  ;; 4. 立即用当前 PCR7 验证 unseal（不通过不继续）。
                  ;;    明文只经管道（tpm2_unseal stdout），不落盘。
                  (let ((sess (string-append workdir "/verify.session.ctx")))
                    (format #t "DBG4 unseal-verify~%")
                    (tpm2-load-sealed! %tcti %tpm2-bin primary seal-pub seal-priv
                                       #:out seal-ctx)
                    (tpm2-start-policy-session! %tcti %tpm2-bin #:out sess)
                    (tpm2-policy-pcr-session! %tcti %tpm2-bin sess #:pcr "sha256:7")
                    (let ((out-port (tpm2-unseal! %tcti %tpm2-bin seal-ctx sess)))
                      (let ((got (utf8->string (get-bytevector-all out-port))))
                        (close-port out-port)
                        (unless (string=? credential got)
                          (error "unseal 自验证失败；中止"))))
                    (tpm2-flush-session! %tcti %tpm2-bin sess)
                    (format #t "unseal 自验证通过。~%"))
                  
                  ;; 5. luksAddKey：credential 经 stdin（--new-keyfile=-）；
                  ;;    用户密码经 0600 临时文件（cryptsetup --key-file=-
                  ;;    是读到 EOF 的语义，无法与 --new-keyfile=- 共享 stdin，
                  ;;    实测结论），文件在 /run tmpfs，dynamic-wind 清理。
                  (let ((pw-file (string-append workdir "/.pw")))
                    (call-with-output-file pw-file
                                           (lambda (p) (display passphrase p)))
                    (chmod pw-file #o600)
                    (format #t "DBG5 luksAddKey~%")
                    (let ((old-slots (or (luks-max-keyslot) -1)))
                      (invoke-with-stdin credential %cryptsetup
                                         "luksAddKey" "--key-file" pw-file
                                         "--new-keyfile=-" (luks-device))
                      (let* ((keyslot (luks-max-keyslot))
                             ;; 回滚闭包：发布失败时删除刚加入的 keyslot
                             (rollback! (lambda ()
                                          (format (current-error-port)
                                                  "回滚：删除 keyslot ~a~%" keyslot)
                                          (invoke-with-stdin passphrase %cryptsetup
                                                             "luksKillSlot"
                                                             "--key-file" pw-file
                                                             (luks-device)
                                                             (number->string keyslot)))))
                        (delete-file pw-file)
                        (unless (and keyslot (> keyslot old-slots))
                          (error "无法确认新 keyslot；中止"))
                        (format #t "TPM keyslot ~a 已加入。~%" keyslot)
                        
                        ;; 6. 验证新 keyslot 可解锁
                        (unless (catch #t
                                  (lambda ()
                                    (invoke-with-stdin credential %cryptsetup
                                                       "open" "--test-passphrase"
                                                       "--key-file=-"
                                                       (luks-device))
                                    #t)
                                  (lambda (key . args) #f))
                          (rollback!)
                          (error "新 keyslot 解锁验证失败；已回滚"))
                        
                        ;; 7. 发布 ESP artifact（解锁前可读；失败回滚 keyslot）
                        (let ((esp-dir %esp-tpm2-dir))
                          (mkdir-p esp-dir)
                          (catch #t
                            (lambda ()
                              (copy-file seal-pub (string-append esp-dir "/seal.pub"))
                              (copy-file seal-priv (string-append esp-dir "/seal.priv"))
                              (call-with-output-file (string-append esp-dir "/metadata.scm")
                                                     (lambda (p)
                                                       (write `((enrollment-id . ,id)
                                                                (keyslot . ,keyslot)
                                                                (pcr7 . ,pcr7-hex)
                                                                (created . ,(current-time)))
                                                              p)
                                                       (newline p))))
                            (lambda (key . args)
                              (rollback!)
                              (apply throw key args)))
                          (format #t "ESP artifact 已发布（~a）~%" esp-dir))
                        
                        ;; 8. /persist 管理副本 + 原子写 state
                        (let ((obj-dir (enrollment-artifact-dir)))
                          (mkdir-p obj-dir)
                          (copy-file seal-pub (string-append obj-dir "/seal.pub"))
                          (copy-file seal-priv (string-append obj-dir "/seal.priv"))
                          (write-tpm2-state!
                           (tpm2-enrollment (id id)
                                            (keyslot keyslot)
                                            (pcr7 pcr7-hex)
                                            (created (current-time))
                                            (notes (if replace?
                                                     '("replace")
                                                     '("initial")))))
                          (format #t "state 已写入（enrollment ~a，keyslot ~a）~%"
                                  id keyslot))
                        
                        (format #t "~%enrollment 完成。下次启动将尝试 TPM 自动解锁；
密码回退不受影响。~%")))))))
            (lambda ()
              (false-if-exception (delete-file-recursively workdir))))))

;;; ────────────────────────────────────────────────────────────
;;; replace：先按 enroll 流程加新 keyslot + 发布，成功后删旧 keyslot。

(define (do-replace)
  "rotate：先按 enroll 流程加新 keyslot + 发布 + 提交 state，成功后用
recovery 密码删除旧 TPM keyslot（recovery keyslot 永不碰）。删除失败时
新 enrollment 保持有效，只打印 WARNING 并提供 orphan 清理命令。"
  (let ((old (read-tpm2-state)))
    (unless (tpm2-enrolled? old)
      (error "尚未 enrollment；请用 enroll 命令"))
    (let* ((old-keyslot (tpm2-enrollment-keyslot old))
           (passphrase (read-passphrase! "输入 recovery LUKS 密码: ")))
      (format #t "== TPM2 enrollment replace（旧 keyslot ~a）==~%" old-keyslot)
      (unless (luks-passphrase-valid? passphrase)
        (error "recovery 密码无法解锁 LUKS；中止"))
      ;; do-enroll 复用同一密码；成功后删除旧 TPM keyslot（绝不先删后建）。
      (do-enroll #:replace? #t #:passphrase passphrase)
      (catch #t
        (lambda ()
          (invoke-with-stdin passphrase %cryptsetup
                             "luksKillSlot" "--key-file=-"
                             (luks-device) (number->string old-keyslot))
          (format #t "旧 TPM keyslot ~a 已删除。~%" old-keyslot))
        (lambda (key . args)
          (format (current-error-port)
                  "WARNING: 删除旧 TPM keyslot ~a 失败；新 enrollment 保持有效。~%"
                  old-keyslot)
          (format (current-error-port)
                  "orphan 清理：cryptsetup luksKillSlot ~a ~a --key-file=<recovery pw>~%"
                  (luks-device) old-keyslot))))))

;;; ────────────────────────────────────────────────────────────
;;; status

(define (status)
  (let ((state (read-tpm2-state)))
    (format #t "== TPM2 enrollment status ==~%")
    (if (tpm2-enrolled? state)
      (begin
       (format #t "  enrolled : ~a (keyslot ~a, ~a)~%"
               (tpm2-enrollment-id state)
               (tpm2-enrollment-keyslot state)
               (tpm2-enrollment-created state))
       (format #t "  pcr-bank : ~a~%" (tpm2-enrollment-pcr-bank state))
       (format #t "  pcr-list : ~a~%" (tpm2-enrollment-pcr-list state))
       (format #t "  pcr7     : ~a~%" (or (tpm2-enrollment-pcr7 state) "（未记录）"))
       (format #t "  ESP 侧   : ~a~%"
               (if (and (file-exists? (string-append %esp-tpm2-dir "/seal.pub"))
                        (file-exists? (string-append %esp-tpm2-dir "/seal.priv")))
                 "完整"
                 "缺失/不完整"))
       (format #t "  /persist 侧: ~a~%"
               (if (enrollment-artifacts-present?
                    state %tpm2-state-dir)
                 "完整"
                 "缺失/不完整")))
      (format #t "  （未 enrollment）~%"))))

;;; ────────────────────────────────────────────────────────────
;;; 入口

(define (main)
  (let ((args (command-line)))
    (if (< (length args) 2)
      (begin
       (display "用法: guix repl tools/tpm2-enroll.scm -- preflight|enroll|replace|status\n")
       (exit 1))
      (case (string->symbol (list-ref args 1))
        ((preflight) (preflight))
        ((enroll) (do-enroll #:replace? #f))
        ((replace) (do-replace))
        ((status) (status))
        (else (display "未知动词\n") (exit 1))))))

(main)
