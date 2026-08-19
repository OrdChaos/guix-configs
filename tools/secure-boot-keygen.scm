;;; Secure Boot 密钥生成（docs/architecture/boot.md（Secure Boot））。
;;;
;;; 只负责生成 PK/KEK/db 的 PEM 私钥与 X.509 证书。
;;; 不生成 .esl/.auth，不读取或写入固件变量。
;;; 私钥不进 Git、不进 /gnu/store。
;;;
;;; 用法：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     shell -m manifests/secure-boot-keygen.scm -- \
;;;     guix repl tools/secure-boot-keygen.scm [目标目录]
;;;
;;; 已存在任何密钥材料时拒绝覆盖；如需重建，手动删除整个密钥目录。

(use-modules (ice-9 format)
             (guixcfg storage model)     ; persist-mount-point（/persist 语义路径 authority）
             (ice-9 match)
             (srfi srfi-1))

(define %default-dir
  (string-append (persist-mount-point "@persist-system") "/keys/secure-boot"))
(define %key-names '("PK" "KEK" "db"))

(define (mkdir-p dir)
  "递归创建目录（core 没有 mkdir -p，手写避免引 (guix build utils)）。"
  (unless (file-exists? dir)
    (mkdir-p (dirname dir))
    (mkdir dir)))

(define (run . args)
  (unless (zero? (status:exit-val (apply system* args)))
    (error "command failed" args)))

(define (key-material-paths dir)
  (append-map
   (lambda (name)
     (list (string-append dir "/" name ".key")
           (string-append dir "/" name ".crt")))
   %key-names))

(define (main args)
  (let ((dir (match (cdr args)
                    (() %default-dir)
                    ((dir) dir)
                    (_
                     (format (current-error-port)
                             "Usage: secure-boot-keygen [directory]~%")
                     (exit 1)))))
    ;; 不允许覆盖部分存在的 keyset。
    ;; 如果上一次生成中途失败，也要求人工确认并删除后重建。
    (let ((existing
           (filter file-exists? (key-material-paths dir))))
      (unless (null? existing)
        (format (current-error-port)
                "Existing Secure Boot key material found; refusing to overwrite:~%")
        (for-each
         (lambda (path)
           (format (current-error-port)
                   "  ~a~%" path))
         existing)
        (format (current-error-port)
                "To regenerate, manually delete the whole directory: ~a~%"
                dir)
        (exit 1)))
    
    (mkdir-p dir)
    (chmod dir #o700)
    
    (for-each
     (lambda (name)
       (let ((key (string-append dir "/" name ".key"))
             (crt (string-append dir "/" name ".crt")))
         (format #t "generated ~a~%" name)
         (run "ukify" "genkey"
              "--secureboot-private-key" key
              "--secureboot-certificate" crt)
         (chmod key #o400)))
     %key-names)
    
    (format #t
            "~%Done. Only key/crt generated:~%
  ~a~%

Next steps:
  1. system init/reconfigure generates and signs the UKI;
  2. then run secure-boot-enroll.scm to build firmware enrollment materials.~%"
            dir)))

(main (command-line))
