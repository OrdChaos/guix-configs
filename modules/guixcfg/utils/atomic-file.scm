;;; 小型 crash-durable 文件提交辅助。
;;;
;;; 目标不是通用事务框架，只解决本项目状态文件/ESP 配置的共同需求：
;;;   1. 新内容先写 PATH.new 并 fsync；
;;;   2. rename 原子替换主文件；
;;;   3. fsync 父目录，让 rename 在掉电后也有持久化保证。
;;;
;;; .prev 的语义由各状态模块自己管理：只有“已成功解析为有效状态”的旧
;;; 内容才允许写入 .prev，避免把损坏主文件覆盖到最后一份好备份上。

(define-module (guixcfg utils atomic-file)
               #:export (fsync-path!
                         atomic-replace-file!
                         atomic-write-file!))

(define (fsync-path! path)
  "对 PATH 对应的文件或目录执行 fsync。
任何 fsync 错误都向上传播；这里不能把 EIO 等真实持久化失败伪装成成功。"
  (let ((fd (open-fdes path O_RDONLY)))
    (dynamic-wind
     (lambda () #t)
     (lambda () (fsync fd))
     (lambda () (close-fdes fd)))))

(define (fsync-parent-directory! path)
  "fsync PATH 的父目录，持久化 rename/unlink 等目录项变化。"
  (fsync-path! (dirname path)))

(define (atomic-replace-file! new path)
  "把已经完整生成的 NEW 原子替换为 PATH，并持久化目录项。
NEW 和 PATH 必须位于同一文件系统。"
  (fsync-path! new)
  (rename-file new path)
  (fsync-parent-directory! path))

(define (atomic-write-file! path writer)
  "调用 WRITER 把完整内容写入 PATH.new，再原子提交到 PATH。"
  (let ((new (string-append path ".new")))
    (call-with-output-file new
                           (lambda (port)
                             (writer port)
                             ;; Guile 的 fsync(port) 会先 flush 端口缓冲区。
                             (fsync port)))
    (rename-file new path)
    (fsync-parent-directory! path)))
