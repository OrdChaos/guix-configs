;;; Boot State 的持久化、旧格式兼容与 .prev 回退测试。
;;;
;;; 注册的公共契约：write-boot-states! 写出的文件可经
;;; read-boot-state-alist 解析（LiveCD 人工救援直接 cat 同一文件，
;;; docs/operations/recovery.md），损坏主文件回退 .prev；
;;; protect-last-good! 维护 GC root。注册表没有部署期程序化读者
;;; （Recovery artifact 由部署脚本从当前 deployment 构建、confirm 时
;;; promote——见 (guixcfg boot uki) / (guixcfg boot recovery)）。

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
     (let ((state (read-boot-state-alist path)))
       (test-equal "writes v2 format" 2 (assq-ref state 'format-version))
       (test-equal "reads last-good generation"
                   7 (assq-ref (assq-ref state 'last-good) 'generation))
       (test-equal "reads cmdline of confirmed boot"
                   "root=/selected-root foo=bar"
                   (assq-ref (assq-ref state 'last-good) 'command-line)))
     
     ;; 第二次提交后 .prev 保存 generation 7；随后人为写入“语法合法但
     ;; 结构非法”的主文件，读取必须判定主文件损坏并回退 .prev。
     (write-boot-states! path 8 "root=/selected-root baz=qux")
     (call-with-output-file path
                            (lambda (port) (write '() port) (newline port)))
     (let ((state (read-boot-state-alist path)))
       (test-equal "falls back to .prev on corrupt structure"
                   7 (assq-ref (assq-ref state 'last-good) 'generation))
       (test-equal "fallback cmdline and generation stay consistent"
                   "root=/selected-root foo=bar"
                   (assq-ref (assq-ref state 'last-good) 'command-line)))
     
     ;; v2：system store identity 持久化与读取
     (write-boot-states! path 9 "root=/selected-root v2=yes"
                         #:system "/gnu/store/abc-system")
     (let ((lg (assq-ref (read-boot-state-alist path) 'last-good)))
       (test-equal "v2 reads generation" 9 (assq-ref lg 'generation))
       (test-equal "v2 reads system identity"
                   "/gnu/store/abc-system" (assq-ref lg 'system))
       (test-equal "v2 reads cmdline"
                   "root=/selected-root v2=yes" (assq-ref lg 'command-line)))
     
     ;; v1 旧格式兼容（无 system identity；写入端总是 v2，v1 只剩
     ;; 历史机器上的存量文件）
     (let ((v1 (string-append dir "/v1.scm")))
       (call-with-output-file v1
                              (lambda (port)
                                (write '((last-good . 3) (command-line . "root=/x")) port)
                                (newline port)))
       (let ((state (read-boot-state-alist v1)))
         (test-equal "v1 compat generation"
                     3 (assq-ref state 'last-good))
         (test-equal "v1 compat cmdline"
                     "root=/x" (assq-ref state 'command-line))))
     
     ;; GC root：原子 symlink 保护 confirmed system
     (let ((root (string-append dir "/gcroots")))
       (protect-last-good! "/gnu/store/abc-system"
                           #:root root #:name "last-good-system")
       (test-equal "GC root symlink points at confirmed system"
                   "/gnu/store/abc-system"
                   (readlink (string-append root "/last-good-system")))
       ;; 原子替换（再次保护新 system）
       (protect-last-good! "/gnu/store/def-system"
                           #:root root #:name "last-good-system")
       (test-equal "GC root atomically replaced"
                   "/gnu/store/def-system"
                   (readlink (string-append root "/last-good-system")))))
   (lambda ()
     (delete-file-recursively dir))))

(test-end)
