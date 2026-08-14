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
                 (read-boot-command-line path))
     
     ;; v2：system store identity 持久化与读取
     (write-boot-states! path 9 "root=/selected-root v2=yes"
                         #:system "/gnu/store/abc-system")
     (test-equal "v2 读取 generation" 9 (read-boot-states path))
     (test-equal "v2 读取 cmdline"
                 "root=/selected-root v2=yes"
                 (read-boot-command-line path))
     (let ((lg (read-boot-last-good path)))
       (test-equal "v2 last-good generation" 9 (car lg))
       (test-equal "v2 last-good system identity"
                   "/gnu/store/abc-system" (cadr lg))
       (test-equal "v2 last-good cmdline"
                   "root=/selected-root v2=yes" (caddr lg)))
     
     ;; v1 旧格式兼容（无 system identity）
     (let ((v1 (string-append dir "/v1.scm")))
       (call-with-output-file v1
                              (lambda (port)
                                (write '((last-good . 3) (command-line . "root=/x")) port)
                                (newline port)))
       (test-equal "v1 兼容 generation" 3 (read-boot-states v1))
       (test-equal "v1 兼容 cmdline" "root=/x" (read-boot-command-line v1))
       (test-equal "v1 last-good system 为 #f"
                   #f (cadr (read-boot-last-good v1))))
     
     ;; GC root：原子 symlink 保护 confirmed system
     (let ((root (string-append dir "/gcroots")))
       (protect-last-good! "/gnu/store/abc-system"
                           #:root root #:name "last-good-system")
       (test-equal "GC root symlink 指向 confirmed system"
                   "/gnu/store/abc-system"
                   (readlink (string-append root "/last-good-system")))
       ;; 原子替换（再次保护新 system）
       (protect-last-good! "/gnu/store/def-system"
                           #:root root #:name "last-good-system")
       (test-equal "GC root 原子替换"
                   "/gnu/store/def-system"
                   (readlink (string-append root "/last-good-system")))))
   (lambda ()
     (delete-file-recursively dir))))

(test-end)
