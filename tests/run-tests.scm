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

(primitive-load "tests/test-atomic-file.scm")
(primitive-load "tests/test-boot-state.scm")
(primitive-load "tests/test-model.scm")
(primitive-load "tests/test-policies.scm")
(primitive-load "tests/test-plan.scm")
(primitive-load "tests/test-validate.scm")
(primitive-load "tests/test-device.scm")
(primitive-load "tests/test-root-generation.scm")
(primitive-load "tests/test-modules-load.scm")

(let ((runner (test-runner-current)))
  (exit (zero? (+ (test-runner-fail-count runner)
                  (test-runner-xfail-count runner)))))
