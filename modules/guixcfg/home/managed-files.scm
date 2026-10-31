;;; 声明式文件投影到用户可写 mixed-authority 目录。
;;;
;;; 与 home-files 的 store symlink 不同，managed-files 在 Home activation
;;; 中把 store 文件原子复制到 target。用于应用需要同时拥有声明式文件与
;;; 运行时写入的目录（如 DSH profile 根）。application 只声明记录；
;;; 部署由本 generic service 执行。

(define-module (guixcfg home managed-files)
  #:use-module (gnu home services) ;home-activation-service-type
  #:use-module (gnu services) ;service-type、service-extension
  #:use-module (guix gexp) ;file-like?、with-imported-modules
  #:use-module (guix modules) ;source-module-closure
  #:use-module (guix records)
  #:use-module (guixcfg utils module-closure) ;guixcfg-module-select?
  #:use-module (guixcfg utils paths) ;valid-relative-path?
  #:use-module (srfi srfi-1) ;concatenate
  #:export (<managed-file> managed-file make-managed-file managed-file?
            managed-file-name managed-file-target managed-file-source
            managed-file-kind managed-files-activation
            managed-files-service-type))

(define-record-type* <managed-file> managed-file make-managed-file
  managed-file?
  (name managed-file-name) ;symbol
  (target managed-file-target) ;string：HOME 相对路径
  (source managed-file-source) ;file-like
  (kind managed-file-kind (default 'file))) ;'file | 'symlink

(define (validate-managed-file file)
  "FILE 合法性检查；违反抛错（fail closed）。"
  (unless (valid-relative-path? (managed-file-target file))
    (error "managed file target must be a HOME-relative safe path"
           (managed-file-name file) (managed-file-target file)))
  (unless (memq (managed-file-kind file) '(file symlink))
    (error "unsupported managed file kind"
           (managed-file-name file) (managed-file-kind file)))
  (unless (file-like? (managed-file-source file))
    (error "managed file source must be a file-like"
           (managed-file-name file) (managed-file-source file)))
  #t)

(define (validate-managed-file-set files)
  "跨贡献检查：同一 target 只能有一个 owner。"
  (let loop ((rest files) (seen '()))
    (when (pair? rest)
      (let ((target (managed-file-target (car rest))))
        (when (member target seen)
          (error "duplicate managed file target" target))
        (loop (cdr rest) (cons target seen))))))

(define (managed-files-activation files)
  "返回把所有 FILES 安装到 $HOME 的 activation gexp。"
  (for-each validate-managed-file files)
  (validate-managed-file-set files)
  (if (null? files)
      #~#t
      (with-imported-modules
          (source-module-closure
           '((guix build utils)
             (guixcfg utils atomic-file)
             (guixcfg utils managed-file))
           #:select? guixcfg-module-select?)
        #~(begin
            (use-modules (guixcfg utils managed-file))
            #$@(map (lambda (file)
                      #~(install-managed-file!
                         (string-append (getenv "HOME") "/"
                                        #$(managed-file-target file))
                         #$(managed-file-source file)
                         '#$(managed-file-kind file)))
                    files)))))

(define managed-files-service-type
  (service-type (name 'managed-files)
                (extensions
                 (list (service-extension home-activation-service-type
                                          managed-files-activation)))
                (compose concatenate)
                (extend append)
                (default-value '())
                (description "Project declared files into a user-writable
HOME directory during Home activation.")))
