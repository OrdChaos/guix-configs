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
             (ice-9 match)
             (srfi srfi-1))

(define %default-dir "/persist/system/keys/secure-boot")
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
                             "用法: secure-boot-keygen [目标目录]~%")
                     (exit 1)))))
    ;; 不允许覆盖部分存在的 keyset。
    ;; 如果上一次生成中途失败，也要求人工确认并删除后重建。
    (let ((existing
           (filter file-exists? (key-material-paths dir))))
      (unless (null? existing)
        (format (current-error-port)
                "发现已有 Secure Boot 密钥材料，拒绝覆盖：~%")
        (for-each
         (lambda (path)
           (format (current-error-port)
                   "  ~a~%" path))
         existing)
        (format (current-error-port)
                "如需重建，请先手动删除整个目录：~a~%"
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
            "~%完成。仅生成 key/crt：~%
  ~a~%

下一步：
  1. system init/reconfigure 生成并签名 UKI；
  2. 再运行 secure-boot-enroll.scm 构建固件注册材料。~%"
            dir)))

(main (command-line))
