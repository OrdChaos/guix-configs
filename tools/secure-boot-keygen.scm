;;; Secure Boot 密钥生成与固件注册材料（docs/boot.md 第 16.3 节）。
;;;
;;; 在目标系统上生成 PK/KEK/db 三件套到 /persist/system/keys/secure-boot/
;;; （或指定目录），并生成固件注册用的 .esl/.auth 文件（enroll/ 子目录）。
;;; 私钥不进 Git、不进 /gnu/store。
;;;
;;; 用法（工具经 installer manifest 提供）：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm \
;;;     -- guix repl tools/secure-boot-keygen.scm [目标目录]
;;;
;;; 已存在密钥时拒绝覆盖；重装需要新信任材料时先手动删除旧目录。
;;;
;;; 生成后注册进固件（Setup Mode 下，PK 最后写——写入即启用 Secure Boot）：
;;;   efi-updatevar -f enroll/db.auth  db
;;;   efi-updatevar -f enroll/KEK.auth KEK
;;;   efi-updatevar -f enroll/PK.auth  PK

(use-modules (ice-9 format)
             (ice-9 match)
             (ice-9 popen)          ; open-pipe*
             (ice-9 textual-ports)  ; get-string-all
             (srfi srfi-13))  ; string-trim-right

(define (mkdir-p dir)
  "递归创建目录（core 没有 mkdir -p，手写避免引 (guix build utils)）。"
  (unless (file-exists? dir)
    (mkdir-p (dirname dir))
    (mkdir dir)))

(define (command-output prog)
  "运行命令并捕获 stdout（system* 继承的是 fd 不是 Scheme port，不能用
with-output-to-string 捕获）。"
  (string-trim-right
   (call-with-port (open-pipe* OPEN_READ prog) get-string-all)))

(define %default-dir "/persist/system/keys/secure-boot")

(define (run . args)
  (unless (zero? (status:exit-val (apply system* args)))
    (error "命令失败" args)))

(define (main args)
  (let ((dir (match (cdr args)
                    (() %default-dir)
                    ((dir) dir)
                    (_ (format (current-error-port)
                               "用法: secure-boot-keygen [目标目录]~%")
                       (exit 1)))))
    (when (file-exists? (string-append dir "/db.key"))
      (format (current-error-port)
              "密钥已存在，拒绝覆盖: ~a~%如需重建请先手动删除该目录。~%" dir)
      (exit 1))
    
    ;; 1. PK/KEK/db 三件套（ukify genkey 产出 PEM 私钥 + X.509 证书）
    (mkdir-p dir)
    (chmod dir #o700)
    (for-each
     (lambda (name)
       (format #t "生成 ~a~%" name)
       (run "ukify" "genkey"
            "--secureboot-private-key" (string-append dir "/" name ".key")
            "--secureboot-certificate" (string-append dir "/" name ".crt"))
       (chmod (string-append dir "/" name ".key") #o400))
     '("PK" "KEK" "db"))
    
    ;; 2. 固件注册材料：.esl（签名列表）→ .auth（带签名的变量写入负载）
    (let ((enroll (string-append dir "/enroll"))
          (guid (command-output "uuidgen")))
      (mkdir-p enroll)
      (for-each
       (lambda (name)
         (run "cert-to-efi-sig-list" "-g" guid
              (string-append dir "/" name ".crt")
              (string-append enroll "/" name ".esl")))
       '("PK" "KEK" "db"))
      ;; 签名链：db ← KEK，KEK ← PK，PK ← PK（自签）
      (run "sbvarsign" "--key" (string-append dir "/KEK.key")
           "--cert" (string-append dir "/KEK.crt")
           "--output" (string-append enroll "/db.auth")
           "db" (string-append enroll "/db.esl"))
      (run "sbvarsign" "--key" (string-append dir "/PK.key")
           "--cert" (string-append dir "/PK.crt")
           "--output" (string-append enroll "/KEK.auth")
           "KEK" (string-append enroll "/KEK.esl"))
      (run "sbvarsign" "--key" (string-append dir "/PK.key")
           "--cert" (string-append dir "/PK.crt")
           "--output" (string-append enroll "/PK.auth")
           "PK" (string-append enroll "/PK.esl")))
    
    (format #t "~%完成。密钥位于 ~a（权限已收紧）。~%~
               固件注册（Setup Mode 下执行，PK 最后写）:~%~
               ~%  efi-updatevar -f ~a/enroll/db.auth  db~%~
               ~%  efi-updatevar -f ~a/enroll/KEK.auth KEK~%~
               ~%  efi-updatevar -f ~a/enroll/PK.auth  PK~%~
               ~%写入 PK 后 Secure Boot 即启用。~%"
            dir dir dir dir)))

(main (command-line))
