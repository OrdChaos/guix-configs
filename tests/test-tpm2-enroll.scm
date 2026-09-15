;;; tpm2-enroll 工具修复的回归测试：
;;;   A. executable resolver：mock bin 目录齐全时 executable-checks 全通过
;;;   B. missing executable：缺 tpm2_pcrread 时 executable-checks 含失败
;;;   C. error binding：(rnrs base) 不再覆盖 Guile 原生 error——replace
;;;      在未 enrollment 时是正常业务错误（非 wrong-number-of-arguments）
;;;   D. 模块 compile/load：tools/tpm2-enroll.scm 无 unbound/wrong-import
;;;   E. rollback password file 在异常处理期间仍存在，随后清理
;;;   F. 新 keyslot 用集合差唯一识别，不会猜测/误删 recovery slot
;;;   G. sealed pair 完整 stage 后才替换 live artifact
;;;   T7-T14. CLI credential 来源解析（--luks-secret / --noninteractive）：
;;;      互斥、status/preflight 拒绝、fail-closed、未知 flag
;;;
;;; 通过 GUIXCFG_TPM2_BIN / GUIXCFG_CRYPTSETUP 指向 mock 目录，在
;;; 本文件内控制加载顺序（%tpm2-bin 在模块加载时求值）。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guix build utils)
             (guixcfg security age)      ; %runtime-identity-dir/path
             (ice-9 ftw)
             (ice-9 rdelim)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13)              ; string-contains
             (srfi srfi-64)
             (system base compile))      ; compile-file（D 测试）

(test-runner-current (test-runner-simple))

(define (write-mock-bin dir names)
  "在 DIR 下创建可执行的 mock 命令。"
  (for-each
   (lambda (name)
     (let ((p (string-append dir "/" name)))
       (call-with-output-file p
                              (lambda (port) (display "#!/bin/sh\nexit 0\n" port)))
       (chmod p #o755)))
   names))

(define (enroll-source-without-main)
  "读 tools/tpm2-enroll.scm，去掉末尾的 (main) 调用（测试内不触发 CLI）。"
  (let ((s (call-with-input-file "tools/tpm2-enroll.scm" get-string-all)))
    (string-join (filter (lambda (l) (not (string=? l "(main)")))
                         (string-split s #\newline))
                 "\n")))

(test-begin "tpm2-enroll")

;; ── Test A/B 共享的 mock 环境（%tpm2-bin 在加载时解析）────────
(let ((mock (mkdtemp "/tmp/guixcfg-tpm2-mock-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     ;; mock 目录包含 enrollment 全部 TPM2 命令 + cryptsetup
     (write-mock-bin mock
                     '("tpm2_pcrread" "tpm2_policypcr" "tpm2_createprimary"
                                      "tpm2_startauthsession" "tpm2_create" "tpm2_load"
                                      "tpm2_unseal" "tpm2_flushcontext" "cryptsetup"))
     (setenv "GUIXCFG_TPM2_BIN" mock)
     (setenv "GUIXCFG_CRYPTSETUP" (string-append mock "/cryptsetup"))
     ;; 生成去 main 的 enroll 源码并加载——%tpm2-bin 解析到 mock
     (call-with-output-file "/tmp/guixcfg-enroll-nomain.scm"
                            (lambda (p) (display (enroll-source-without-main) p)))
     (primitive-load "/tmp/guixcfg-enroll-nomain.scm")
     
     ;; Test A：齐全 → executable-checks 全通过
     (test-assert "A: all executable checks pass with full mocks"
                  (every identity (executable-checks)))
     
     ;; Test B：删 tpm2_pcrread → 检查失败（不静默 PASS）
     (delete-file (string-append mock "/tpm2_pcrread"))
     (test-assert "B: executable check fails without tpm2_pcrread"
                  (not (every identity (executable-checks))))
     
     ;; Test C：error binding——replace 在未 enrollment 时正常业务错误
     (test-assert "C: replace without enrollment throws proper business error (not arity)"
                  (let ((caught
                         (catch #t
                           (lambda () (do-replace #f) #f)
                           (lambda (k . a)
                             (if (eq? k 'misc-error)
                               ;; error 单参数时：a = (#f "~A" (MESSAGE) #f)
                               (string-contains (car (caddr a)) "No existing TPM enrollment")
                               #f)))))
                    caught)))
   (lambda ()
     (unsetenv "GUIXCFG_TPM2_BIN")
     (unsetenv "GUIXCFG_CRYPTSETUP")
     (false-if-exception (delete-file "/tmp/guixcfg-enroll-nomain.scm"))
     (delete-file-recursively mock))))

(define (misc-error-message a)
  "从 catch 的 misc-error args A 提取用户消息。Guile `error` 抛出的
形态随模块执行方式（解释 load vs compile-file 编译 thunk，实测
2026-08）有两种：(#f \"~A\" (MSG) #f) 与 (#f MSG () #f)——断言
必须两者兼容，不能只认 (car (caddr a))。"
  (let ((irritants (caddr a)))
    (if (and (pair? irritants) (string? (car irritants)))
      (car irritants)
      (cadr a))))

;; ── E-G：rollback/publication 的可注入边界 ─────────────────
(let ((tmp (mkdtemp "/tmp/guixcfg-enroll-rollback-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (let ((pw-file (string-append tmp "/pw"))
           (visible-during-handler? #f)
           (rollback-args #f))
       (catch 'forced-failure
         (lambda ()
           (call-with-passphrase-file
            "recovery-password" pw-file
            (lambda (path)
              (catch 'publish-failure
                (lambda () (throw 'publish-failure))
                (lambda args
                  (set! visible-during-handler?
                    (and (file-exists? path)
                         (= #o600 (logand #o777 (stat:mode (stat path))))))
                  (rollback-keyslot!
                   3 "recovery-password" path
                   #:invoke-proc
                   (lambda args (set! rollback-args args)))
                  (throw 'forced-failure)))))
           #f)
         (lambda args #t))
       (test-assert "E: password file survives rollback handler and is then removed"
                    (and visible-during-handler?
                         rollback-args
                         (string=? "recovery-password" (car rollback-args))
                         (member "luksKillSlot" rollback-args)
                         (member pw-file rollback-args)
                         (string=? "3" (last rollback-args))
                         (not (file-exists? pw-file)))))
     
     (test-equal "F1: a reused lower-numbered slot is identified exactly"
                 1 (added-keyslot '(0 2) '(0 1 2)))
     (test-assert "F2: ambiguous slot changes refuse a rollback target"
                  (not (added-keyslot '(0) '(0 1 2))))
     (test-assert "F3: no slot change refuses a rollback target"
                  (not (added-keyslot '(0 1) '(0 1))))
     
     (let* ((source-dir (string-append tmp "/source"))
            (target-dir (string-append tmp "/target"))
            (source-pub (string-append source-dir "/seal.pub"))
            (source-priv (string-append source-dir "/seal.priv"))
            (target-pub (string-append target-dir "/seal.pub"))
            (target-priv (string-append target-dir "/seal.priv")))
       (mkdir-p source-dir)
       (mkdir-p target-dir)
       (call-with-output-file source-pub (lambda (p) (display "new-pub" p)))
       (call-with-output-file source-priv (lambda (p) (display "new-priv" p)))
       (call-with-output-file target-pub (lambda (p) (display "old-pub" p)))
       (call-with-output-file target-priv (lambda (p) (display "old-priv" p)))
       (catch 'copy-failed
         (lambda ()
           (publish-sealed-pair!
            source-pub source-priv target-dir
            #:copy-proc
            (lambda (source target)
              (if (string-suffix? "seal.priv" source)
                (throw 'copy-failed)
                (copy-file source target))))
           #f)
         (lambda args #t))
       (test-assert "G1: staging failure leaves the live sealed pair unchanged"
                    (and (string=? "old-pub"
                                   (call-with-input-file target-pub get-string-all))
                         (string=? "old-priv"
                                   (call-with-input-file target-priv get-string-all))
                         (not (file-exists? (string-append target-dir "/.seal.pub.new")))
                         (not (file-exists? (string-append target-dir "/.seal.priv.new")))))
       (publish-sealed-pair! source-pub source-priv target-dir)
       (test-assert "G2: successful publication replaces both sealed blobs"
                    (and (string=? "new-pub"
                                   (call-with-input-file target-pub get-string-all))
                         (string=? "new-priv"
                                   (call-with-input-file target-priv get-string-all))))))
   (lambda ()
     (false-if-exception (delete-file-recursively tmp)))))

;; ── T7-T14：CLI credential 来源解析 ────────────────────────
;; parse-command/parse-credential-flag 是纯函数（不 exit、不改环境）；
;; --luks-secret 的 fail-closed 前置在解析时发生（任何 TPM mutation 前）。
(let ((no-identity-dir (mkdtemp "/tmp/guixcfg-enroll-noident-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (parameterize ((%runtime-identity-dir no-identity-dir)
                    (%runtime-identity-path
                     (string-append no-identity-dir "/stable-identity"))
                    (%installed-identity-path
                     (string-append no-identity-dir "/installed-identity")))
                   ;; T7：默认（无 flag）→ interactive reader（0 参 thunk，
                   ;; 调用时提示并从 stdin 读取——不能是裸 read-passphrase!，
                   ;; 后者需要 prompt 参数，当 thunk 调会
                   ;; wrong-number-of-arguments（实测 bug））
                   (test-assert "T7: enroll defaults to interactive source"
                                (call-with-values
                                 (lambda () (parse-command '("prog" "enroll")))
                                 (lambda (cmd source)
                                   (and (eq? cmd 'enroll)
                                        (string=? "pw"
                                                  (with-input-from-string
                                                   "pw\n"
                                                   source))))))
                   ;; T8：--luks-secret 无 identity（runtime 与 installed
                   ;; 都没有）→ fail-closed 报错
                   (test-assert "T8: enroll --luks-secret without identity fails closed"
                                (catch #t
                                  (lambda () (parse-command '("prog" "enroll" "--luks-secret")) #f)
                                  (lambda (k . a)
                                    (and (eq? k 'misc-error)
                                         (string-contains (misc-error-message a)
                                                          "no stable identity")))))
                   ;; T9：--noninteractive → stdin 直读
                   (test-assert "T9: enroll --noninteractive reads one stdin line"
                                (call-with-values
                                 (lambda ()
                                   (parse-command '("prog" "enroll" "--noninteractive")))
                                 (lambda (cmd source)
                                   (and (eq? cmd 'enroll)
                                        (string=? "pipe-pw"
                                                  (with-input-from-string "pipe-pw\n"
                                                                          source))))))
                   ;; T10：两个来源 flag 互斥
                   (test-assert "T10: --luks-secret and --noninteractive are mutually exclusive"
                                (catch #t
                                  (lambda ()
                                    (parse-command '("prog" "enroll"
                                                            "--luks-secret" "--noninteractive"))
                                    #f)
                                  (lambda (k . a)
                                    (and (eq? k 'misc-error)
                                         (string-contains (car (caddr a))
                                                          "mutually exclusive")))))
                   ;; T11：replace --luks-secret 同样 fail-closed
                   (test-assert "T11: replace --luks-secret without identity fails closed"
                                (catch #t
                                  (lambda () (parse-command '("prog" "replace" "--luks-secret")) #f)
                                  (lambda (k . a)
                                    (and (eq? k 'misc-error)
                                         (string-contains (misc-error-message a)
                                                          "no stable identity")))))
                   ;; T12：status 拒绝 credential flag
                   (test-assert "T12: status rejects credential source flags"
                                (catch #t
                                  (lambda () (parse-command '("prog" "status" "--luks-secret")) #f)
                                  (lambda (k . a)
                                    (and (eq? k 'misc-error)
                                         (string-contains (car (caddr a))
                                                          "does not accept")))))
                   ;; T13：preflight 拒绝 credential flag
                   (test-assert "T13: preflight rejects credential source flags"
                                (catch #t
                                  (lambda ()
                                    (parse-command '("prog" "preflight" "--noninteractive"))
                                    #f)
                                  (lambda (k . a)
                                    (and (eq? k 'misc-error)
                                         (string-contains (car (caddr a))
                                                          "does not accept")))))
                   ;; T14：未知 flag 报错
                   (test-assert "T14: unknown flag errors"
                                (catch #t
                                  (lambda () (parse-command '("prog" "enroll" "--bogus")) #f)
                                  (lambda (k . a)
                                    (and (eq? k 'misc-error)
                                         (string-contains (car (caddr a))
                                                          "unknown option")))))))
   (lambda ()
     (false-if-exception (delete-file-recursively no-identity-dir)))))

;; tools/*.scm 的 compile 检查已并入 test-modules-load.scm（那里的
;; current-warning-port 捕获才是真正生效的写法——本处旧实现用
;; with-output-to-string 抓 current-output-port，Guile 编译警告走
;; current-warning-port，导致该断言永远为真）。

(test-end "tpm2-enroll")
