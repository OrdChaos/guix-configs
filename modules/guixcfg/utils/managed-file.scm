;;; 可写 mixed-authority 容器中的声明式文件投影原语。
;;;
;;; 与 home-files 的 store symlink 不同，这些文件必须位于应用可写目录
;;; （例如 DSH profile 会写入同目录的运行时文件）。activation 只替换
;;; 声明的 target，不删除其它文件；内容相同则 no-op；target 类型冲突
;;; fail closed，绝不静默删除/替换用户数据。

(define-module (guixcfg utils managed-file)
  #:use-module (guix build utils) ;dump-port、mkdir-p
  #:use-module (guixcfg utils atomic-file) ;atomic-write-file!
  #:use-module (ice-9 textual-ports) ;get-string-all
  #:export (install-managed-file!))

(define (entry-type path)
  "PATH 的 lstat 类型；不存在返回 #f。"
  (false-if-exception (stat:type (lstat path))))

(define (same-contents? target source)
  "TARGET 与 SOURCE 是否都是 regular file 且内容相同。"
  (and (eq? 'regular (entry-type target))
       (string=? (call-with-input-file target get-string-all)
                 (call-with-input-file source get-string-all))))

(define (install-managed-file! target source kind)
  "把 SOURCE 投影到 TARGET，KIND 为 'file 或 'symlink。

file：target 必须是 regular file 或不存在；内容相同则不再写。
symlink：target 必须是 symlink 或不存在；已有 symlink 必须指向 SOURCE。
其它类型冲突直接抛错（fail closed）。父目录按需创建。"
  (mkdir-p (dirname target))
  (case kind
    ((file)
     (let ((type (entry-type target)))
       (unless (or (not type) (eq? type 'regular))
         (error "managed file target exists but is not a regular file"
                target type))
       (unless (and type (same-contents? target source))
         (atomic-write-file! target
                             (lambda (port)
                               (call-with-input-file source
                                 (lambda (in)
                                   (dump-port in port)))))))
     (chmod target #o644))
    ((symlink)
     (let ((type (entry-type target)))
       (cond
        ((not type)
         (symlink source target))
        ((eq? type 'symlink)
         (let ((current (readlink target)))
           (unless (string=? current source)
             (error "managed symlink target points elsewhere"
                    target current source))))
        (else
         (error "managed symlink target exists but is not a symlink"
                target type)))))
    (else
     (error "unsupported managed file kind" kind))))
