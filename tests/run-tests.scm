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

(dynamic-wind
 (lambda () (setenv "GUIX_CONFIG_FACTS" %test-facts-file))
 (lambda ()
   (primitive-load "tests/test-atomic-file.scm")
   (primitive-load "tests/test-boot-state.scm")
   (primitive-load "tests/test-process.scm")
   (primitive-load "tests/test-spawn.scm")
   (primitive-load "tests/test-model.scm")
   (primitive-load "tests/test-policies.scm")
   (primitive-load "tests/test-plan.scm")
   (primitive-load "tests/test-validate.scm")
   (primitive-load "tests/test-device.scm")
   (primitive-load "tests/test-root-generation.scm")
   (primitive-load "tests/test-modules-load.scm")
   (primitive-load "tests/test-machine-facts.scm")
   (primitive-load "tests/test-luks-passphrase.scm")
   (primitive-load "tests/test-tpm2-state.scm")
   (primitive-load "tests/test-tpm-unlock.scm")
   (primitive-load "tests/test-recovery.scm")
   (primitive-load "tests/test-device-resolver.scm")
   (primitive-load "tests/test-commit-root.scm"))
 (lambda ()
   (unsetenv "GUIX_CONFIG_FACTS")
   (when (file-exists? %test-facts-file)
     (delete-file %test-facts-file))))

(let ((runner (test-runner-current)))
  (exit (zero? (+ (test-runner-fail-count runner)
                  (test-runner-xfail-count runner)))))
