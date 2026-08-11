;;; Boot State 的持久化、旧格式兼容与 .prev 回退测试。

(use-modules (guixcfg boot boot-state)
             (guix build utils)
             (srfi srfi-64))

(test-begin "boot-state")

(let* ((dir (mkdtemp "/tmp/guixcfg-boot-state-XXXXXX"))
       (path (string-append dir "/boot-states.scm")))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (write-boot-states! path 7 "root=/selected-root foo=bar")
      (test-equal "读取 last-good generation" 7 (read-boot-states path))
      (test-equal "读取确认启动时 cmdline"
                  "root=/selected-root foo=bar"
                  (read-boot-command-line path))

      ;; 第二次提交后 .prev 保存 generation 7；随后人为写入“语法合法但
      ;; 结构非法”的主文件，读取必须判定主文件损坏并回退 .prev。
      (write-boot-states! path 8 "root=/selected-root baz=qux")
      (call-with-output-file path
        (lambda (port) (write '() port) (newline port)))
      (test-equal "结构损坏时回退 .prev" 7 (read-boot-states path))
      (test-equal "回退时 cmdline 与 generation 同源"
                  "root=/selected-root foo=bar"
                  (read-boot-command-line path)))
    (lambda ()
      (delete-file-recursively dir))))

(test-end)
