;;; 测试运行器。模块代码使用 (guix records)，所以需要 Guix 的模块路径，
;;; 通过锁定频道运行（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
;;; 全部通过时退出码为 0，有失败时退出码为 1。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (srfi srfi-64))

;; 必须先设置 runner，再加载测试文件：
;; SRFI-64 的计数器都记录在“当前 runner”上。
(test-runner-current (test-runner-simple))

;; (guixcfg hosts vm) 会加载 (guixcfg system file-systems)，其顶层对
;; luks-uuid 做 fail-closed 检查（无 facts 时模块加载即报错）。因此全套
;; 测试在临时 facts 环境下运行（不碰真实宿主 /persist）：显式提供测试
;; UUID，让 modules-compile、%os 实例化等测试可以正常加载 host 模块。
(define %test-facts-file
  (string-append "/tmp/guixcfg-test-facts-"
                 (number->string (getpid)) ".scm"))

(call-with-output-file %test-facts-file
                       (lambda (port)
                         (write '((luks-uuid . "00000000-0000-0000-0000-000000000000")) port)
                         (newline port)))

;; 每个测试文件都调用 (test-runner-current (test-runner-simple))，把
;; 当前 runner 换成自己的新 runner——最后的 runner 只反映最后一个
;; 文件，直接看 (test-runner-current) 会让前面套件的失败被掩盖。
;; 这里在每个文件加载后立刻摘取其 runner 的计数，累计判定退出码。
(define %fail-total 0)
(define %xfail-total 0)

(define (run-file file)
  (primitive-load file)
  (let ((r (test-runner-current)))
    (set! %fail-total (+ %fail-total (test-runner-fail-count r)))
    (set! %xfail-total (+ %xfail-total (test-runner-xfail-count r)))))

(dynamic-wind
 (lambda () (setenv "GUIX_CONFIG_FACTS" %test-facts-file))
 (lambda ()
   (for-each run-file
             '("tests/test-atomic-file.scm"
               "tests/test-boot-state.scm"
               "tests/test-process.scm"
               "tests/test-spawn.scm"
               "tests/test-model.scm"
               "tests/test-policies.scm"
               "tests/test-plan.scm"
               "tests/test-validate.scm"
               "tests/test-device.scm"
               "tests/test-root-generation.scm"
               "tests/test-modules-load.scm"
               "tests/test-machine-facts.scm"
               "tests/test-luks-passphrase.scm"
               "tests/test-tpm2-state.scm"
               "tests/test-tpm-unlock.scm"
               "tests/test-recovery.scm"
               "tests/test-device-resolver.scm"
               "tests/test-commit-root.scm"
               "tests/test-tpm2-enroll.scm"
               "tests/test-ui-language.scm"
               "tests/test-ssh.scm"
               "tests/test-user-persistence.scm"
               "tests/test-session.scm"
               "tests/test-home.scm"
               "tests/test-home-pivot.scm"
               "tests/test-users.scm"
               "tests/test-age.scm"
               "tests/test-secrets.scm"
               "tests/test-accounts.scm"
               "tests/test-store-leakage.scm"
               "tests/test-readiness.scm")))
 (lambda ()
   (unsetenv "GUIX_CONFIG_FACTS")
   (when (file-exists? %test-facts-file)
     (delete-file %test-facts-file))))

(exit (zero? (+ %fail-total %xfail-total)))
