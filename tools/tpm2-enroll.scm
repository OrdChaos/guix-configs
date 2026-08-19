;;; TPM2 enrollment 工具（PCR7-only）：把独立随机 LUKS credential
;;; 密封到当前 PCR7，并把 credential 加入独立 LUKS keyslot。
;;;
;;; 用法（从仓库根目录，目标系统上以 root 运行）：
;;;   guix repl tools/tpm2-enroll.scm -- preflight
;;;   guix repl tools/tpm2-enroll.scm -- enroll [--luks-secret|--noninteractive]
;;;   guix repl tools/tpm2-enroll.scm -- replace [--luks-secret|--noninteractive]
;;;   guix repl tools/tpm2-enroll.scm -- status
;;;
;;; LUKS recovery passphrase 来源（互斥三选一；绝不静默回退）：
;;;   默认      交互读取（tty 关闭回显；stdin 非 tty 时直读）
;;;   --luks-secret      从 age-encrypted luks-recovery.age 解密
;;;                      （livecd：需先 secrets unlock 用 runtime S；
;;;                       已装系统：自动用 installed S
;;;                       /persist/system/keys/age/identity——无需
;;;                       unlock；两个 identity 都缺失才中止）
;;;   --noninteractive   从 stdin 直读一行（脚本/自动化注入）
;;; status/preflight 不接受任何 credential 来源 flag。
;;; 来源解析统一走 (guixcfg security credential-source)（与
;;; disk-install 共享同一 resolver；docs/operations/installation.md）。
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
             (guixcfg security credential-source) ; resolve-luks-passphrase-source
             (guixcfg storage model)     ; %system-partlabel
             (guixcfg utils process)
             (guixcfg utils spawn)       ; wait-exit（unseal 管道回收）
             ((guix build utils) #:select (mkdir-p invoke delete-file-recursively)) ; #:select：不整体导入，避免 guile-user 下 delete 覆盖警告
             (ice-9 format)
             (ice-9 match)
             (ice-9 ftw)                ; scandir
             (ice-9 rdelim)             ; read-line
             (ice-9 regex)              ; string-match
             (ice-9 binary-ports)       ; get-bytevector-all/n!
             (ice-9 popen)              ; open-pipe*
             (rnrs bytevectors)         ; make-bytevector
             ((rnrs base) #:select (let-values))  ; 只取 let-values——
             ; 全量导入会覆盖 Guile 原生 error
             ;（R6RS error 签名 who/message/irritants，
             ; 实测 replace 报 wrong-number-of-arguments）
             (srfi srfi-1)              ; filter-map、count
             (srfi srfi-13))            ; string-tokenize

;;; ────────────────────────────────────────────────────────────
;;; 工具定位与环境

;; TPM2 binaries 与 cryptsetup 的确定性来源：system profile
;; （/run/current-system/profile）。tpm2-tools-compat 由 host 的
;; packages 显式加入 profile（vm.scm），cryptsetup 在 %system-packages。
;; 不模糊扫描 /gnu/store：store 条目名是 <hash>-tpm2-tools-compat-5.8，
;; 前缀匹配不可靠，且多 generation/多版本时会选错（实测）。
;; GUIXCFG_TPM2_BIN / GUIXCFG_CRYPTSETUP 仅供测试/调试覆盖。
(define %tpm2-bin (or (getenv "GUIXCFG_TPM2_BIN")
                      "/run/current-system/profile/bin"))
(define %cryptsetup (or (getenv "GUIXCFG_CRYPTSETUP")
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

;; enrollment 真正需要执行的 TPM2 命令集合（tpm2-tools.scm 的实际调用）。
;; preflight 必须验证 executable 可达，禁止“preflight PASS 而 enroll
;; 才发现缺二进制”（实测 bug：%tpm2-bin 曾解析到不含 tpm2 的路径）。
(define %enroll-tpm2-commands
  '("tpm2_pcrread" "tpm2_policypcr" "tpm2_createprimary"
                   "tpm2_startauthsession" "tpm2_create" "tpm2_load"
                   "tpm2_unseal" "tpm2_flushcontext"))

(define (executable-checks)
  "enrollment 需要的 executables 检查（#t/#f 列表，含打印）。
可单独测试（tests/test-tpm2-enroll.scm）。"
  (define (check name ok?)
    (format #t "  [~a] ~a~%" (if ok? "ok" "FAIL") name)
    ok?)
  (define (check-executable path name)
    ;; (guix build utils) 的 file-executable? 在 guix repl 环境未导出、
    ;; (ice-9 posix) 在 time-machine repl 环境不可用（均实测），
    ;; 用 guile 核心的 stat mode 位检查（零额外模块依赖）。
    (check (string-append name " executable: " path)
           (and (file-exists? path)
                (let ((st (stat path)))
                  (not (zero? (logand (stat:mode st) #o111)))))))
  (append
   (list (check-executable %cryptsetup "cryptsetup"))
   (map (lambda (name)
          (check-executable (string-append %tpm2-bin "/" name) name))
        %enroll-tpm2-commands)))

(define (preflight-checks)
  "preflight 全量检查结果（#t/#f 列表，含打印）。可单独测试。"
  (define (check name ok?)
    (format #t "  [~a] ~a~%" (if ok? "ok" "FAIL") name)
    ok?)
  (append
   (list
    (check "TPM2 device available"
           (tpmrm0-present?))
    (check "current system is not Recovery"
           (not (recovery-boot?)))
    (check "target device is LUKS2"
           (and (file-exists? (luks-device)) (luks-is-luks2?)))
    (check "Secure Boot enabled (SecureBoot==1 and not SetupMode)"
           (secure-boot-enabled?))
    (check "ESP mounted (/efi/EFI/Guix exists)"
           (file-exists? "/efi/EFI/Guix"))
    (check "/persist writable"
           (dir-writable? (persist-mount-point "@persist-system"))))
   (executable-checks)))

(define (preflight)
  (format #t "== TPM2 enrollment preflight ==~%")
  (let* ((results (preflight-checks))
         (fail-count (count (lambda (x) (not x)) results)))
    (format #t "preflight: ~a failure(s)~%" fail-count)
    (exit (if (zero? fail-count) 0 1))))

;;; ────────────────────────────────────────────────────────────
;;; enrollment 主体（enroll / replace 共用）

(define* (do-enroll #:key (replace? #f) (passphrase-source #f))
         "执行 enrollment（enroll / replace 共用主体）。PASSPHRASE-SOURCE\n为 reader thunk（interactive / --luks-secret / --noninteractive 的解析\n结果）；#f 时交互读取（do-replace 传入以复用一次密码输入）。\n所有明文临时材料只存在于 /run/guixcfg/tpm2-enroll/（tmpfs、root-only、\nunique 目录）；dynamic-wind 保证正常与异常路径都清理。"
         (define id (string-append "enroll-" (number->string (current-time))))
         (define workdir (string-append "/run/guixcfg/tpm2-enroll/" id))
         ;; ── 硬性前置检查（任一不满足即中止，不做任何修改）────────
         (unless (tpmrm0-present?) (error "TPM2 device unavailable"))
         (when (recovery-boot?) (error "enrollment forbidden in Recovery mode"))
         (unless
           (and (file-exists? (luks-device)) (luks-is-luks2?))
           (error "target is not LUKS2"))
         (unless
           (secure-boot-enabled?)
           (error "Secure Boot not enabled/provable; refusing TPM enrollment"))
         (unless (file-exists? "/efi/EFI/Guix") (error "ESP not mounted or layout missing (/efi/EFI/Guix)"))
         (let ((existing (read-tpm2-state)))
           (when (and (tpm2-enrolled? existing) (not replace?))
             (error "TPM enrollment already exists (~a). Use replace to re-enroll"
                    (tpm2-enrollment-id existing))))
         (dynamic-wind
          (lambda () #t)
          (lambda ()
            
            (mkdir-p workdir)
            (let ((passphrase
                   (or (and passphrase-source (passphrase-source))
                       (read-passphrase! "Enter recovery LUKS passphrase: "))))
              
              (unless
                (luks-passphrase-valid? passphrase)
                (error "recovery passphrase cannot unlock LUKS; aborting"))
              (format #t "recovery passphrase verified.~%")
              
              ;; 2. 显示当前 PCR7 并确认（Secure Boot 已启用状态下的机器 policy）
              (let* ((pcr7-hex (tpm2-pcrread! %tcti %tpm2-bin "sha256:7"))
                     (pcr7-file (string-append workdir "/pcr7.bin")))
                (format #t "current PCR7 = ~a~%" pcr7-hex)
                (format #t "Confirm enrollment while Secure Boot is enabled? Type yes: ")
                (force-output)
                (unless (string-ci=? (read-line) "yes") (error "not confirmed; aborting enrollment"))
                ;; 3. 随机 credential + sealed object
                (let* ((credential (random-credential))
                       (policy-file (string-append workdir "/policy.pcr.digest"))
                       (primary (string-append workdir "/primary.ctx"))
                       (seal-pub (string-append workdir "/seal.pub"))
                       (seal-priv (string-append workdir "/seal.priv"))
                       (seal-ctx (string-append workdir "/seal.ctx")))
                  ;; trial PolicyPCR（期望值 = 当前 PCR7）
                  (tpm2-pcrread! %tcti %tpm2-bin "sha256:7" #:out pcr7-file)
                  
                  (tpm2-policy-pcr-digest!
                   %tcti
                   %tpm2-bin
                   pcr7-file
                   #:pcr
                   "sha256:7"
                   #:out
                   policy-file)
                  (tpm2-createprimary! %tcti %tpm2-bin #:out primary)
                  (tpm2-create-sealed!
                   %tcti
                   %tpm2-bin
                   primary
                   policy-file
                   credential
                   #:public-out
                   seal-pub
                   #:private-out
                   seal-priv)
                  (format #t "sealed object created (credential held in memory only)~%")
                  ;; 4. 立即用当前 PCR7 验证 unseal（不通过不继续）。
                  (let ((sess (string-append workdir "/verify.session.ctx")))
                    
                    (tpm2-load-sealed!
                     %tcti
                     %tpm2-bin
                     primary
                     seal-pub
                     seal-priv
                     #:out
                     seal-ctx)
                    (tpm2-start-policy-session! %tcti %tpm2-bin #:out sess)
                    (tpm2-policy-pcr-session! %tcti %tpm2-bin sess #:pcr "sha256:7")
                    (let-values
                     (((out-port unseal-pid)
                       (tpm2-unseal! %tcti %tpm2-bin seal-ctx sess)))
                     (let ((got (utf8->string (get-bytevector-all out-port))))
                       (close-port out-port)
                       (let ((st (wait-exit unseal-pid)))
                         (unless (zero? st) (error "unseal exited with non-zero status" st)))
                       (unless (string=? credential got) (error "unseal self-check failed; aborting"))))
                    (tpm2-flush-session! %tcti %tpm2-bin sess)
                    (format #t "unseal self-check passed.~%"))
                  ;; 5. luksAddKey：credential 经 stdin（--new-keyfile=-）；
                  (let ((pw-file (string-append workdir "/.pw")))
                    (call-with-output-file
                     pw-file
                     (lambda (p) (display passphrase p)))
                    (chmod pw-file 384)
                    
                    (let ((old-slots (or (luks-max-keyslot) -1)))
                      (invoke-with-stdin
                       credential
                       %cryptsetup
                       "luksAddKey"
                       "--key-file"
                       pw-file
                       "--new-keyfile=-"
                       (luks-device))
                      (let* ((keyslot (luks-max-keyslot))
                             (rollback!
                              (lambda ()
                                (format
                                 (current-error-port)
                                 "Rollback: removing keyslot ~a~%"
                                 keyslot)
                                (invoke-with-stdin
                                 passphrase
                                 %cryptsetup
                                 "luksKillSlot"
                                 "--key-file"
                                 pw-file
                                 (luks-device)
                                 (number->string keyslot)))))
                        (delete-file pw-file)
                        (unless
                          (and keyslot (> keyslot old-slots))
                          (error "cannot confirm new keyslot; aborting"))
                        (format #t "TPM keyslot ~a added.~%" keyslot)
                        (unless
                          ;; 6. 验证新 keyslot 可解锁
                          (catch #t
                            (lambda ()
                              (invoke-with-stdin
                               credential
                               %cryptsetup
                               "open"
                               "--test-passphrase"
                               "--key-file=-"
                               (luks-device))
                              #t)
                            (lambda (key . args) #f))
                          (rollback!)
                          (error "new keyslot unlock verification failed; rolled back"))
                        ;; 7. 发布 ESP artifact（解锁前可读；失败回滚 keyslot）
                        (let ((esp-dir %esp-tpm2-dir))
                          (mkdir-p esp-dir)
                          (catch #t
                            (lambda ()
                              (copy-file
                               seal-pub
                               (string-append esp-dir "/seal.pub"))
                              (copy-file
                               seal-priv
                               (string-append esp-dir "/seal.priv"))
                              (call-with-output-file
                               (string-append esp-dir "/metadata.scm")
                               (lambda (p)
                                 (write `((enrollment-id unquote id)
                                          (keyslot unquote keyslot)
                                          (pcr7 unquote pcr7-hex)
                                          (created unquote (current-time)))
                                        p)
                                 (newline p))))
                            (lambda (key . args)
                              (rollback!)
                              (apply throw key args)))
                          (format #t "ESP artifact published (~a)~%" esp-dir))
                        ;; 8. /persist 管理副本 + 原子写 state
                        (let ((obj-dir (enrollment-artifact-dir)))
                          (mkdir-p obj-dir)
                          (copy-file seal-pub (string-append obj-dir "/seal.pub"))
                          (copy-file seal-priv (string-append obj-dir "/seal.priv"))
                          (write-tpm2-state!
                           (tpm2-enrollment
                            (id id)
                            (keyslot keyslot)
                            (pcr7 pcr7-hex)
                            (created (current-time))
                            (notes (if replace? '("replace") '("initial")))))
                          (format
                           #t
                           "state written (enrollment ~a, keyslot ~a)~%"
                           id
                           keyslot))
                        (format #t "~%enrollment complete. Next boot will attempt TPM auto-unlock;\npassphrase fallback is unaffected.~%"))))))))
          (lambda () (false-if-exception (delete-file-recursively workdir)))))

(define (do-replace passphrase-source)
  "rotate：先按 enroll 流程加新 keyslot + 发布 + 提交 state，成功后用
recovery 密码删除旧 TPM keyslot（recovery keyslot 永不碰）。删除失败时
新 enrollment 保持有效，只打印 WARNING 并提供 orphan 清理命令。
PASSPHRASE-SOURCE 为 reader thunk（互斥来源之一；#f 时交互读取）。"
  (let ((old (read-tpm2-state)))
    (unless (tpm2-enrolled? old)
      (error "No existing TPM enrollment; use the enroll command"))
    (let* ((old-keyslot (tpm2-enrollment-keyslot old))
           (passphrase (or (and passphrase-source (passphrase-source))
                           (read-passphrase! "Enter recovery LUKS passphrase: "))))
      (format #t "== TPM2 enrollment replace (old keyslot ~a) ==~%" old-keyslot)
      (unless (luks-passphrase-valid? passphrase)
        (error "recovery passphrase cannot unlock LUKS; aborting"))
      ;; do-enroll 复用同一密码；成功后删除旧 TPM keyslot（绝不先删后建）。
      ;; 密码以 reader thunk 传入（do-enroll 的 #:passphrase-source 契约；
      ;; 传裸字符串会 wrong-keyword / 按 thunk 调用字符串）。
      (do-enroll #:replace? #t #:passphrase-source (lambda () passphrase))
      (catch #t
        (lambda ()
          (invoke-with-stdin passphrase %cryptsetup
                             "luksKillSlot" "--key-file=-"
                             (luks-device) (number->string old-keyslot))
          (format #t "old TPM keyslot ~a removed.~%" old-keyslot))
        (lambda (key . args)
          (format (current-error-port)
                  "WARNING: failed to remove old TPM keyslot ~a; new enrollment remains valid.~%"
                  old-keyslot)
          (format (current-error-port)
                  "Orphan cleanup: cryptsetup luksKillSlot ~a ~a --key-file=<recovery pw>~%"
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
       (format #t "  pcr7     : ~a~%" (or (tpm2-enrollment-pcr7 state) (not recorded)))
       (format #t "  ESP side  : ~a~%"
               (if (and (file-exists? (string-append %esp-tpm2-dir "/seal.pub"))
                        (file-exists? (string-append %esp-tpm2-dir "/seal.priv")))
                 "complete"
                 "missing/incomplete"))
       (format #t "  /persist side: ~a~%"
               (if (enrollment-artifacts-present?
                    state %tpm2-state-dir)
                 "complete"
                 "missing/incomplete")))
      (format #t "  (no enrollment)~%"))))

;;; ────────────────────────────────────────────────────────────
;;; CLI 解析（纯函数，可单测）

(define (parse-credential-flag flags)
  "解析 enroll/replace 的 credential 来源 flag，返回 passphrase reader
thunk。三个来源互斥：'() → 交互读取；--luks-secret → age 解密（identity
缺失在解析时立即失败，绝不回退交互）；--noninteractive → stdin 直读一行。
互斥违规/未知 flag 抛错。"
  (match flags
         (()
          ;; reader thunk：调用时提示并读取（read-passphrase! 需要
          ;; prompt 参数——不能把裸 procedure 当 0 参 thunk 返回，
          ;; 否则 do-enroll 调用时 wrong-number-of-arguments）。
          (lambda () (read-passphrase! "Enter recovery LUKS passphrase: ")))
         (("--luks-secret")
          (resolve-luks-passphrase-source 'luks-secret))
         (("--noninteractive")
          ;; stdin 直读一行（脚本/自动化注入；无提示、无回显控制）。
          (lambda () (read-line)))
         (("--luks-secret" "--noninteractive")
          (error "credential sources are mutually exclusive; use exactly one of --luks-secret / --noninteractive"))
         (("--noninteractive" "--luks-secret")
          (error "credential sources are mutually exclusive; use exactly one of --luks-secret / --noninteractive"))
         (_ (error "unknown option for enroll/replace" flags))))

(define (usage)
  (display "Usage: guix repl tools/tpm2-enroll.scm -- preflight|status\n")
  (display "       guix repl tools/tpm2-enroll.scm -- enroll|replace [--luks-secret|--noninteractive]\n"))

(define (parse-command args)
  "解析 CLI 参数（(command-line) 全列表）。返回 (values command source)。
COMMAND：'preflight | 'enroll | 'replace | 'status。
SOURCE：passphrase reader thunk（enroll/replace）；其余 #f。
任何违规（未知命令、未知 flag、互斥冲突、status/preflight 携带
credential flag、--luks-secret 的 fail-closed 前置）都在此抛错——
发生在任何 TPM/LUKS mutation 之前。"
  (let* ((rest (cdr args))
         (cmd (and (pair? rest) (string->symbol (car rest))))
         (flags (cdr rest)))
    (define (reject-credential-flags! name)
      (unless (null? flags)
        (error (string-append name " does not accept credential source flags")
               flags)))
    (case cmd
      ((preflight) (reject-credential-flags! "preflight") (values 'preflight #f))
      ((status)    (reject-credential-flags! "status")    (values 'status #f))
      ((enroll)    (values 'enroll (parse-credential-flag flags)))
      ((replace)   (values 'replace (parse-credential-flag flags)))
      (else (throw 'command-error "unknown command" (and cmd (symbol->string cmd)))))))

;;; ────────────────────────────────────────────────────────────
;;; 入口

(define (main)
  (if (< (length (command-line)) 2)
    (begin (usage) (exit 1))
    (catch 'command-error
      (lambda ()
        (catch 'misc-error
          (lambda ()
            (let-values (((cmd source) (parse-command (command-line))))
                        (case cmd
                          ((preflight) (preflight))
                          ((status) (status))
                          ((enroll) (do-enroll #:replace? #f #:passphrase-source source))
                          ((replace) (do-replace source)))))
          (lambda (key . args)
            ;; error：args = (#f "~A" (MESSAGE . IRRITANTS) #f)
            (format (current-error-port) "error: ~a~%" (car (caddr args)))
            (exit 1))))
      (lambda (key message . args)
        (format (current-error-port) "error: ~a~%" message)
        (usage)
        (exit 1)))))

(main)
