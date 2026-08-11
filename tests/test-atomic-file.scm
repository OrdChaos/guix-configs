;;; crash-durable 文件提交辅助的基础行为测试。

(use-modules (guixcfg utils atomic-file)
             (guix build utils)
             (ice-9 textual-ports)
             (srfi srfi-64))

(test-begin "atomic-file")

(let* ((dir (mkdtemp "/tmp/guixcfg-atomic-file-XXXXXX"))
       (path (string-append dir "/state.scm")))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (atomic-write-file! path
                          (lambda (port) (display "first\n" port)))
      (test-equal "首次提交写入主文件"
                  "first\n"
                  (call-with-input-file path get-string-all))

      (atomic-write-file! path
                          (lambda (port) (display "second\n" port)))
      (test-equal "再次提交原子替换主文件"
                  "second\n"
                  (call-with-input-file path get-string-all)))
    (lambda ()
      (delete-file-recursively dir))))

(test-end)
