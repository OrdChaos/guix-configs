;;; blue enroll 的 machine-bound enrollment 编排层
;;; （docs/operations/installation.md 的 Blue 主路径）。
;;;
;;; 职责边界：
;;;   - 只在【目标系统已正常启动】的环境运行（§18 fail closed：
;;;     非目标环境直接拒绝）；
;;;   - TPM mutation 机制唯一 authority 是 tools/tpm2-enroll.scm
;;;     （本模块经其 argv 执行，绝不重写 PCR policy / keyslot /
;;;     sealed object / TPM2 state）；
;;;   - Secure Boot 材料构建（keygen / keystore）归 blue install；
;;;     本模块只编排【固件 NVRAM 写入】（sbkeysync db/KEK 先、PK 后，
;;;     写 PK 才退出 Setup Mode）与 TPM enrollment，且固件写入前
;;;     必须显式人工确认（§22/§23）；
;;;   - idempotency（§25）：TPM 已 compatible → 报告 OK 零 mutation；
;;;     固件已 enrolled（SecureBoot=1 && SetupMode=0）→ 跳过写入；
;;;     TPM state 存在但 artifacts 不完整 → fail closed（不自动
;;;     replace，提示显式处理）；
;;;   - 顺序：firmware enrollment 先于 TPM enrollment（tpm2-enroll 的
;;;     preflight 硬性要求 SecureBoot=1 && SetupMode=0）。
;;;
;;; 退出码契约（同 install）：0 成功/已合规；1 前置/配置失败（未
;;; mutation）；2 部分 mutation 无法安全自动继续；3 用户显式中止。
;;;
;;; 本模块不执行任何子进程；subprocess 经调用方注入的 EXEC
;;; （(lambda (argv) -> exit-status)，cwd = 仓库根）。dry-run 由调用方
;;; 保证（绝不调用 enroll-transaction!）。

(define-module (guixcfg security enroll)
               #:use-module (guixcfg security tpm2 state)   ; read-tpm2-state / tpm2-enrolled? / enrollment-artifacts-present? / %tpm2-state-dir
               #:use-module (guixcfg system machine-facts)  ; resolve-facts-path / %default-machine-facts-path / load-machine-facts
               #:use-module (guixcfg storage model)         ; persist-mount-point
               #:use-module (guixcfg boot layout)           ; %esp-mount-point / %esp-tpm2-directory
               #:use-module (guix records)
               #:use-module (ice-9 match)
               #:use-module (ice-9 rdelim)
               #:use-module (ice-9 format)
               #:use-module (ice-9 binary-ports)            ; get-bytevector-all
               #:use-module (ice-9 ftw)                     ; scandir（persist-readable?）
               #:use-module (rnrs bytevectors)              ; bytevector-length / bytevector-u8-ref
               #:use-module (srfi srfi-1)
               #:use-module (srfi srfi-13)                  ; string-tokenize / string-trim
               #:export (;; 探针（可注入测试）
                         efi-variable-byte
                         secure-boot-firmware-state
                         tpm2-enrollment-status
                         sb-keys-complete?
                         keystore-complete?
                         collect-enrollment-probes
                         classify-enrollment-probes
                         ;; 状态记录
                         <enrollment-status>
                         enrollment-status make-enrollment-status enrollment-status?
                         enrollment-status-tpm enrollment-status-firmware
                         enrollment-status-keys enrollment-status-keystore
                         enrollment-status-facts
                         ;; 只读检查（user 态与 dry-run 共用）
                         enroll-readonly-checks
                         ;; 计划输出与固件确认匹配（纯）
                         enroll-plan-lines
                         firmware-confirm-lines
                         firmware-confirmed?
                         ;; argv（纯）
                         sbkeysync-binary
                         tpm2-tool-argv
                         tpm2-enroll-argv
                         ;; 事务（root 阶段执行；dry-run 绝不调用）
                         enroll-transaction!
                         enroll-next-step-lines))

;;; ────────────────────────────────────────────────────────────
;;; 固定事实

;; SB 材料路径（install 阶段写入；与 boot/uki.scm 的 keydir 同一
;; authority——persist-mount-point 拼写）。
(define %sb-keydir
  (string-append (persist-mount-point "@persist-system")
                 "/keys/secure-boot"))

(define %sb-keystore (string-append %sb-keydir "/keystore"))

(define %sb-key-file-names '("PK.key" "PK.crt" "KEK.key" "KEK.crt"
                             "db.key" "db.crt"))

(define %keystore-auth-paths '("PK/PK.auth" "KEK/KEK.auth"
                               "db/db.auth"))

(define %firmware-confirm-token "ENROLL-FIRMWARE")

;;; ────────────────────────────────────────────────────────────
;;; 探针（全部只读；efivarfs 读取与 tools/tpm2-enroll.scm 的
;;; secure-boot-enabled? 同一 canonical 路径与字节布局）

(define (efi-variable-byte name)
  "读取 efivarfs 变量 NAME 的值字节（4 字节 attributes + 值）。
不可读/过短返回 #f。"
  (let ((path (string-append "/sys/firmware/efi/efivars/"
                             name
                             "-8be4df61-93ca-11d2-aa0d-00e098032b8c")))
    (and (file-exists? path)
         (let ((bv (call-with-input-file path
                                         (lambda (p)
                                           (get-bytevector-all p)))))
           (and (>= (bytevector-length bv) 5)
                (bytevector-u8-ref bv 4))))))

(define (secure-boot-firmware-state)
  "固件状态：'enrolled（SecureBoot=1 且 SetupMode=0，注册完成）/
'setup-mode（SB=0 且 SetupMode=1，待注册）/ 'unclear（其余组合或
efivarfs 不可读——fail closed，绝不猜）。"
  (let ((sb (efi-variable-byte "SecureBoot"))
        (sm (efi-variable-byte "SetupMode")))
    (cond
      ((and (= sb 1) (= sm 0)) 'enrolled)
      ((and (= sb 0) (= sm 1)) 'setup-mode)
      (else 'unclear))))

(define (esp-tpm2-artifacts-present?)
  "ESP 侧 sealed blobs 完整（解锁前读取副本；与 tools/tpm2-enroll.scm
  的发布路径同一 authority）。"
  (let ((dir (string-append %esp-mount-point "/" %esp-tpm2-directory)))
    (and (file-exists? (string-append dir "/seal.pub"))
         (file-exists? (string-append dir "/seal.priv")))))

(define (tpm2-enrollment-status)
  "TPM 状态：'absent（无 state）/ 'compatible（state + /persist + ESP
artifacts 齐全）/ 'incomplete（state 存在但 artifacts 缺失——
不自动 replace，fail closed）/ 'unreadable（state 不可读，如非 root）。"
  (let ((state (false-if-exception (read-tpm2-state))))
    (cond
      ((not (tpm2-enrolled? state)) 'absent)
      ((and (enrollment-artifacts-present? state %tpm2-state-dir)
            (esp-tpm2-artifacts-present?))
       'compatible)
      (else 'incomplete))))

(define (sb-keys-complete?)
  (every (lambda (f) (file-exists? (string-append %sb-keydir "/" f)))
         %sb-key-file-names))

(define (keystore-complete?)
  (every (lambda (f) (file-exists? (string-append %sb-keystore "/" f)))
         %keystore-auth-paths))

(define (sb-keydir-readable?)
  "keydir 内容可读（scandir 成功）。root 恒成功；普通用户对 0700
root 目录失败——user 态必须区分「不可读」与「不存在」：EACCES 与
ENOENT 都被 scandir 折叠为 #f，存在性由 file-exists? 单独判定
（不可读 ≠ 不存在，不得把 root-only 状态误报成 missing）。"
  (false-if-exception (scandir %sb-keydir)))

(define (sb-keystore-readable?)
  (false-if-exception (scandir %sb-keystore)))

(define (facts-ok?)
  "machine facts 可解析且含 boot-critical luks-uuid。"
  (let ((path (false-if-exception
               (resolve-facts-path (getenv "GUIX_CONFIG_FACTS")
                                   %default-machine-facts-path))))
    (and path
         (let ((facts (false-if-exception (load-machine-facts path))))
           (and facts (assq-ref facts 'luks-uuid))))))

(define (collect-enrollment-probes)
  "收集 enrollment 相关可观察事实 → alist（纯分类的输入）。只读。"
  `((tpm . ,(tpm2-enrollment-status))
    (firmware . ,(secure-boot-firmware-state))
    (sb-keys . ,(sb-keys-complete?))
    (keystore . ,(keystore-complete?))
    (facts . ,(facts-ok?))
    (sbkeysync . ,(false-if-exception (file-exists? (sbkeysync-binary))))
    (tpm-device . ,(file-exists? "/dev/tpmrm0"))
    (current-system . ,(file-exists? "/run/current-system"))
    (persist . ,(file-exists? (persist-mount-point "@persist-system")))
    (esp . ,(file-exists?
             (string-append %esp-mount-point "/EFI/Guix")))))

(define-record-type* <enrollment-status>
                     enrollment-status make-enrollment-status
                     enrollment-status?
                     (tpm      enrollment-status-tpm)      ; 'absent | 'compatible | 'incomplete | 'unreadable
                     (firmware enrollment-status-firmware) ; 'enrolled | 'setup-mode | 'unclear
                     (keys     enrollment-status-keys)     ; #t/#f
                     (keystore enrollment-status-keystore) ; #t/#f
                     (facts    enrollment-status-facts)    ; #t/#f
                     (sbkeysync enrollment-status-sbkeysync (default #f))
                     (tpm-device enrollment-status-tpm-device (default #f))
                     (current-system enrollment-status-current-system
                                     (default #f))
                     (persist enrollment-status-persist (default #f))
                     (esp enrollment-status-esp (default #f)))

(define (classify-enrollment-probes probes)
  "PROBES（collect-enrollment-probes）→ <enrollment-status>。纯。"
  (enrollment-status
   (tpm (assq-ref probes 'tpm))
   (firmware (assq-ref probes 'firmware))
   (keys (assq-ref probes 'sb-keys))
   (keystore (assq-ref probes 'keystore))
   (facts (assq-ref probes 'facts))
   (sbkeysync (assq-ref probes 'sbkeysync))
   (tpm-device (assq-ref probes 'tpm-device))
   (current-system (assq-ref probes 'current-system))
   (persist (assq-ref probes 'persist))
   (esp (assq-ref probes 'esp))))

;;; ────────────────────────────────────────────────────────────
;;; 只读检查（user 态与 dry-run；硬性环境判定 + 信息性读取）

;; /persist/system 是 root 0700：非 root 用户连遍历都做不到。soft?
;; 模式下这种权限性不可读降级为 info（blue -n enroll 的 user 态）；
;; root 事务（#:soft? #f）一律硬性。
;; （不用 (ice-9 posix) 的 access?/X_OK——pinned guile 环境解析不到
;; 该模块；scandir 的 EACCES 语义等价。）
(define (persist-readable?)
  (false-if-exception
   (scandir (persist-mount-point "@persist-system"))))

(define* (enroll-readonly-checks root host #:key (soft? #t))
  "((label . thunk) ...)：thunk 返回 (ok . detail) / (fail . detail) /
(info . detail)。SOFT? #t（user 态/dry-run）时 root-only 状态降级为
info；#f（root 事务）全部硬性。"
  (let* ((status (classify-enrollment-probes (collect-enrollment-probes)))
         (persist-ok? (or (persist-readable?) (not soft?))))
    (list
     (cons "installed system"
           (lambda ()
             (if (and (enrollment-status-current-system status)
                      (enrollment-status-persist status))
               '(ok . #f)
               (cons 'fail
                     "this does not look like the installed target system (/run/current-system and /persist/system are required)"))))
     (cons "machine facts"
           (lambda ()
             (cond
               ((enrollment-status-facts status) '(ok . #f))
               (persist-ok?
                (cons 'fail "machine facts unreadable or missing luks-uuid"))
               (else '(info . "requires root to read")))))
     (cons "ESP boot artifacts"
           (lambda ()
             (if (enrollment-status-esp status)
               '(ok . #f)
                (cons 'fail "/efi/EFI/Guix missing (ESP not mounted or not installed)"))))
     (cons "Secure Boot keys"
           (lambda ()
             (cond
               ((enrollment-status-keys status) '(ok . #f))
               ;; 目录确实不存在 = 真缺失（ENOENT 非权限伪影），soft 态
               ;; 也 fail——不把真缺失伪装成「需 root」。
               ((not (file-exists? %sb-keydir))
                (cons 'fail
                      (format #f "SB key material missing under ~a (run blue install or tools/secure-boot-keygen.scm)"
                              %sb-keydir)))
               ;; 目录在但内容不可读（普通用户 vs 0700 root）→ info。
               ((and soft? (not (sb-keydir-readable?)))
                '(info . "requires root to read"))
               (else
                (cons 'fail
                      (format #f "SB key material missing under ~a (run blue install or tools/secure-boot-keygen.scm)"
                              %sb-keydir))))))
     (cons "Secure Boot keystore"
           (lambda ()
             (cond
               ((enrollment-status-keystore status) '(ok . #f))
               ;; 关键：普通用户无法遍历 0700 root keydir 时，对
               ;; keystore 的 stat 是 EACCES 不是 ENOENT——file-exists?
               ;; 同样返回 #f。绝不能把权限伪影判成"真缺失"：
               ;; keydir 在但不可遍历 → soft 态降级 info。
               ((and soft?
                     (file-exists? %sb-keydir)
                     (not (sb-keydir-readable?)))
                '(info . "requires root to read"))
               ;; 可遍历（root，或 keydir 权限宽松）时的真缺失。
               ((not (file-exists? %sb-keystore))
                (cons 'fail
                      (format #f "SB keystore missing under ~a (run blue install or tools/secure-boot-enroll.scm)"
                              %sb-keystore)))
               ;; keystore 在但 0700 不可读（权限伪影，非缺失）。
               ((and soft? (not (sb-keystore-readable?)))
                '(info . "requires root to read"))
               (else
                (cons 'fail
                      (format #f "SB keystore missing under ~a (run blue install or tools/secure-boot-enroll.scm)"
                              %sb-keystore))))))
     (cons "sbkeysync available"
           (lambda ()
             (if (enrollment-status-sbkeysync status)
               '(ok . #f)
                (cons 'fail "sbkeysync not found (system profile sbsigntools)"))))
     (cons "TPM device"
           (lambda ()
             (if (enrollment-status-tpm-device status)
               '(ok . #f)
               (cons 'fail "/dev/tpmrm0 missing"))))
     (cons "TPM enrollment"
           (lambda ()
             (case (enrollment-status-tpm status)
               ((compatible) '(ok . "already enrolled"))
               ((absent) '(ok . "not enrolled yet"))
               ((incomplete)
                (cons 'fail
                      "enrollment state exists but artifacts are incomplete (incompatible; resolve manually)"))
               (else '(info . "state unreadable (needs root)")))))
     (cons "firmware state"
           (lambda ()
             (case (enrollment-status-firmware status)
               ((enrolled) '(ok . "Secure Boot active, Setup Mode off"))
               ((setup-mode) '(ok . "Setup Mode (SecureBoot=0, SetupMode=1)"))
               (else
                (cons 'fail
                      "firmware state unclear (efivarfs unreadable or SecureBoot/SetupMode combination unexpected); put the firmware in Setup Mode and retry"))))))))

;;; ────────────────────────────────────────────────────────────
;;; 计划输出与固件确认（纯）

(define (firmware-action status)
  (case (enrollment-status-firmware status)
    ((enrolled) "already enrolled (skip)")
    ((setup-mode) "enroll PK/KEK/db (sbkeysync; PK last — exits Setup Mode)")
    (else "BLOCKED (firmware state unclear)")))

(define (tpm-action status)
  (case (enrollment-status-tpm status)
    ((compatible) "already enrolled (skip)")
    ((absent) "enroll using current policy (PolicyPCR sha256:7)")
    ((incomplete) "BLOCKED (incompatible enrollment — handle manually)")
    (else "requires root to read state")))

(define (enroll-plan-lines status host)
  "§24 格式的 ENROLLMENT PLAN 文本行列表。"
  (append
   (list "ENROLLMENT PLAN" ""
         (format #f "Host: ~a" host) ""
         "TPM:"
         (if (enrollment-status-tpm-device status)
           "  device: /dev/tpmrm0"
           "  device: MISSING")
         (format #f "  current: ~a"
                 (case (enrollment-status-tpm status)
                   ((compatible) "enrolled")
                   ((absent) "not enrolled")
                   ((incomplete) "enrolled but incomplete")
                   (else "unreadable")))
         (format #f "  action: ~a" (tpm-action status))
         ""
         "Secure Boot:"
         (format #f "  keys: ~a"
                 (if (enrollment-status-keys status) "present" "missing"))
         (format #f "  auth artifacts: ~a"
                 (if (enrollment-status-keystore status)
                   "present" "missing"))
         (format #f "  firmware: ~a"
                 (case (enrollment-status-firmware status)
                   ((enrolled) "Secure Boot active (Setup Mode off)")
                   ((setup-mode) "Setup Mode")
                   (else "unclear")))
         (format #f "  action: ~a" (firmware-action status))
         ""
         "Mutations:"
         "  LUKS keyslot (TPM credential)"
         "  TPM sealed state"
         "  firmware NVRAM (PK/KEK/db)"
         "")))

(define (firmware-confirm-lines status)
  "固件写入前的显式确认文本（§23：当前状态 / 计划操作 /
回滚与恢复影响）。"
  (list
   ""
   "Firmware enrollment confirmation"
   ""
   (format #f "Current firmware state: ~a"
           (case (enrollment-status-firmware status)
             ((setup-mode) "Setup Mode (SecureBoot=0, SetupMode=1)")
             ((enrolled) "already enrolled")
             (else "unclear")))
   "Planned operation: write db, KEK, PK via sbkeysync (db/KEK first,"
   "PK last). Writing PK enables Secure Boot and exits Setup Mode."
   ""
   "Rollback/recovery implication: after PK is written the firmware"
   "enforces Secure Boot — only artifacts signed by our db will load."
   "Re-entering Setup Mode requires clearing keys via the firmware UI"
   "(enrollment is one-way). A changed PK/KEK/db changes PCR7 and"
   "invalidates any existing TPM-sealed credential until re-enrolled."
   ""
   (format #f "Type ~a to proceed:" %firmware-confirm-token)))

(define (firmware-confirmed? input)
  "只有逐字输入固件确认 token 才通过；EOF/其他输入一律不通过。"
  (and (string? input) (string=? input %firmware-confirm-token)))

;;; ────────────────────────────────────────────────────────────
;;; argv（纯）

(define (sbkeysync-binary)
  "sbkeysync 的确定性来源：system profile（GUIXCFG_SBKEYSYNC 仅供
测试/调试覆盖）。"
  (or (let ((v (getenv "GUIXCFG_SBKEYSYNC")))
        (and v (not (string-null? v)) v))
      "/run/current-system/profile/bin/sbkeysync"))

(define (tpm2-tool-argv root guile site action flags)
  "tools/tpm2-enroll.scm 的 argv：直接跑 guix 自带的 guile（T3 实测：
guix repl 在 3.0.11 下有 dynamic-wind arity 问题），-L 指向 guix
site 与仓库 modules。ACTION ∈ preflight|status|enroll|replace。"
  `(,guile "--no-auto-compile"
           "-L" ,site
           "-L" ,(string-append root "/modules")
           "-s" ,(string-append root "/tools/tpm2-enroll.scm")
           ,action ,@flags))

(define (resolve-guix-guile!)
  "在 PATH 找 guix（sudo 的 secure_path 不含 system profile 时回退到
  /run/current-system/profile/bin/guix——目标系统的确定性位置），读其
  shebang 得到同 store 的 guile 绝对路径；返回 (values guile
  guix-site-dir)。找不到即抛错（fail closed）。"
  (let ((guix-bin
         (or (search-path
              (string-split (or (getenv "PATH") "") #\:)
              "guix")
             (and (file-exists? "/run/current-system/profile/bin/guix")
                  "/run/current-system/profile/bin/guix"))))
    (unless guix-bin
      (error "guix not found in PATH (needed to run the TPM2 tool)"))
    (let ((shebang (call-with-input-file guix-bin
                                         (lambda (p) (read-line p)))))
      (unless (and (string? shebang) (string-prefix? "#!" shebang))
        (error "guix is not a script with a shebang" guix-bin))
      (let* ((tokens (string-tokenize (substring shebang 2)))
             (guile (and (pair? tokens) (car tokens))))
        (unless (and guile (file-exists? guile))
          (error "cannot resolve guix's guile interpreter" guix-bin
                 shebang))
        (values guile
                (string-append
                 (dirname (dirname guile))
                 "/share/guile/site/" (effective-version)))))))

(define (tpm2-enroll-argv root action flags)
  "ACTION + FLAGS 的完整 tpm2-enroll argv（含 guile 解析）。"
  (call-with-values resolve-guix-guile!
    (lambda (guile site)
      (tpm2-tool-argv root guile site action flags))))

;;; ────────────────────────────────────────────────────────────
;;; 事务（root 阶段；dry-run 绝不调用）

(define (enroll-next-step-lines)
  (list ""
        "Enrollment complete. Normal operation is ready."
        "No automatic reboot."))

(define* (enroll-transaction! root host
                              #:key exec on-firmware-confirm)
         "执行 enrollment 事务（含 idempotency / fail-closed 判定）。
返回退出码 0/1/2/3。EXEC 契约见模块头；ON-FIRMWARE-CONFIRM 是固件
写入确认 UI（返回 #f = 用户中止）。"
         (if (not (zero? (getuid)))
           (begin
            (format (current-error-port)
                    "enroll transaction requires root (effective UID 0)~%")
            1)
           (let ((status (classify-enrollment-probes
                          (collect-enrollment-probes)))
                 (mutated? #f))
             ;; 'enroll-exit 异常携带退出码用于提前返回；
             ;; 其余异常一律按部分 mutation 分类（2，除非未 mutation → 1）。
             (catch #t
               (lambda ()
                 ;; ── preflight（硬性；失败 = 1，未 mutation）──
                 (let ((failures
                        (filter-map
                         (lambda (check)
                           (match ((cdr check))
                                  (('fail . detail)
                                   (cons (car check) detail))
                                  (_ #f)))
                         (enroll-readonly-checks root host #:soft? #f))))
                   (unless (null? failures)
                     (for-each
                      (lambda (f)
                        (format (current-error-port)
                                "preflight FAIL: ~a: ~a~%" (car f) (cdr f)))
                      failures)
                     (throw 'enroll-exit 1)))
                 (when (eq? (enrollment-status-tpm status) 'unreadable)
                   (format (current-error-port)
                           "TPM state unreadable even as root; cannot assess enrollment.~%")
                   (throw 'enroll-exit 1))
                 ;; ── 计划打印 ──
                 (for-each (lambda (line) (format #t "~a~%" line))
                           (enroll-plan-lines status host))
                 ;; ── 1. firmware enrollment（先于 TPM：TPM preflight
                 ;;        要求 SecureBoot=1 && SetupMode=0）──
                 (case (enrollment-status-firmware status)
                   ((enrolled)
                    (format #t "~%firmware already enrolled; skipping.~%"))
                   ((setup-mode)
                    (format #t "~%firmware is in Setup Mode.~%")
                    (unless (on-firmware-confirm status)
                      (format (current-error-port)
                              "~%Firmware enrollment declined; nothing was written.~%")
                      (throw 'enroll-exit 3))
                    (set! mutated? #t)
                    (let ((sbkeysync (sbkeysync-binary))
                          (keystore %sb-keystore))
                      (format #t "  writing db/KEK...~%")
                      (let ((s1 (exec `(,sbkeysync "--keystore"
                                                   ,keystore
                                                   "--verbose"))))
                        (unless (zero? s1)
                          (error "sbkeysync (db/KEK) failed" s1)))
                      (format #t "  writing PK (exits Setup Mode)...~%")
                      (let ((s2 (exec `(,sbkeysync "--keystore"
                                                   ,keystore
                                                   "--verbose" "--pk"))))
                        (unless (zero? s2)
                          (error "sbkeysync (PK) failed" s2)))))
                   (else
                    (format (current-error-port)
                            "~%firmware state unclear; put the firmware in Setup Mode (SecureBoot=0, SetupMode=1) and re-run.~%")
                    (throw 'enroll-exit 1)))
                 ;; ── 2. TPM enrollment（idempotent 自动；incompatible
                 ;;        fail closed）──
                 (case (enrollment-status-tpm status)
                   ((compatible)
                    (format #t "~%TPM already enrolled; skipping (no mutation).~%"))
                   ((absent)
                    (format #t "~%enrolling TPM (PolicyPCR sha256:7)...~%")
                    (set! mutated? #t)
                    (let ((s (exec (tpm2-enroll-argv root "enroll"
                                                     '("--luks-secret")))))
                      (unless (zero? s)
                        (error "tpm2-enroll failed" s))))
                   ((incomplete)
                    (format (current-error-port)
                            "~%TPM enrollment exists but artifacts are incomplete; refusing to replace automatically.~%Recovery: inspect 'guix repl tools/tpm2-enroll.scm -- status' and run replace explicitly (or repair artifacts).~%")
                    (throw 'enroll-exit 2))
                   (else
                    (error "TPM state unreadable")))
                 ;; ── 3. post-enrollment 验证（§38：不止看 exit 0）──
                 (let ((after (classify-enrollment-probes
                               (collect-enrollment-probes))))
                   (cond
                     ((not (eq? (enrollment-status-tpm after)
                                'compatible))
                      (format (current-error-port)
                              "post-enrollment FAIL: TPM status is ~a (expected compatible).~%"
                              (enrollment-status-tpm after))
                      2)
                     ((eq? (enrollment-status-firmware after) 'unclear)
                      (format (current-error-port)
                              "post-enrollment FAIL: firmware state unreadable after enrollment.~%")
                      2)
                     (else
                      (format #t "~%post-enrollment validation passed: TPM compatible, firmware ~a.~%"
                              (enrollment-status-firmware after))
                      (for-each (lambda (l) (format #t "~a~%" l))
                                (enroll-next-step-lines))
                      0))))
               (lambda (key . args)
                 (if (eq? key 'enroll-exit)
                   (car args)
                   (begin
                    (format (current-error-port)
                            "~%Enrollment stopped.~%error: ~s ~s~%"
                            key args)
                    (format (current-error-port)
                            "~%Recovery: re-run 'blue enroll ~a' — already-enrolled parts are detected and skipped.~%"
                            host)
                    (if mutated? 2 1))))))))