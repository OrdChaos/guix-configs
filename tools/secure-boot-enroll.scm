;;; Secure Boot 注册材料构建（docs/architecture/boot.md（Secure Boot））。
;;;
;;; 安全模型（实机策略）：自有 PK/KEK/db + 微软兼容证书 + 固件默认值。
;;;   PK：  只有我们自己的（平台所有权归本机）
;;;   KEK： 我们的 KEK + Microsoft KEK CAs + 固件 KEKDefault
;;;   db：  我们的 db + Microsoft db CAs（含 Option ROM CA 2023，
;;;         显卡 OpROM 需要）+ 固件 dbDefault
;;;
;;; 输出 sbkeysync 兼容的 keystore：<keydir>/keystore/{PK,KEK,db}/*.auth
;;;
;;; 用法（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     shell -m manifests/secure-boot-enroll.scm -- \
;;;     guix repl tools/secure-boot-enroll.scm [keydir]
;;;
;;; keydir 默认为 /persist/system/keys/secure-boot（LiveCD 安装时指向
;;; /mnt/persist/...）。微软证书来自 (guixcfg security certificates)
;;; （source 为 virelith 频道 microsoft-secure-boot-certificates 包内
;;; 文件，固定 sha256 在包内，经 store 取文件）；固件默认值
;;; （dbDefault/KEKDefault）经 efi-readvar 现读，读不到就跳过。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path（从仓库根目录运行）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg storage model)     ; persist-mount-point（/persist 语义路径 authority）
             (guixcfg security certificates)
             (guix packages)          ; package-derivation（构建证书包）
             (guix store)
             (guix monads)
             (guix gexp)              ; lower-object、file-append?
             (guix derivations)     ; derivation->output-path
             (ice-9 format)
             (ice-9 match)
             (ice-9 popen)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define %default-keydir
  (string-append (persist-mount-point "@persist-system") "/keys/secure-boot"))
(define %ms-owner-guid "77fa9abd-0359-4d32-bd60-28f4e78f784b")  ; Microsoft

;; keygen 必须完整产出这六个文件；缺任何一个都不能构建 keystore。
(define %required-key-files
  '("PK.key"
    "PK.crt"
    "KEK.key"
    "KEK.crt"
    "db.key"
    "db.crt"))

(define (missing-key-files keydir)
  (filter
   (lambda (name)
     (not (file-exists?
           (string-append keydir "/" name))))
   %required-key-files))

(define (mkdir-p dir)
  (unless (file-exists? dir)
    (mkdir-p (dirname dir))
    (mkdir dir)))

(define (run . args)
  (unless (zero? (status:exit-val (apply system* args)))
    (error "command failed" args)))

(define (command-output . args)
  (string-trim-right
   (call-with-port (apply open-pipe* OPEN_READ args) get-string-all)))

(define (esl-of crt out guid)
  "把 PEM 证书转成 EFI Signature List。"
  (run "cert-to-efi-sig-list" "-g" guid crt out))

(define (pem-of-der der out)
  "DER 证书转 PEM（origin 里的微软证书是 DER 格式）。"
  (run "openssl" "x509" "-inform" "DER" "-in" der
       "-outform" "PEM" "-out" out))

(define (firmware-esl var out)
  "读固件默认变量（如 dbDefault），成功且非空返回 #t，否则 #f。"
  (catch #t
    (lambda ()
      (run "efi-readvar" "-v" var "-o" out)
      (> (stat:size (stat out)) 0))
    (lambda _ #f)))

(define (cert-store-paths certs)
  "把 vendor 证书的 source（file-append 进包内文件）materialize 为
store 文件路径。先构建证书数据包——repl 环境不会隐式构建依赖；包是
轻量 data package（copy-build-system，fixed-output 源已缓存则纯离线，
缺失时由 daemon 下载）。lower-object 对 file-append 只降级 base（包
derivation），路径 = output + suffix，这里显式拼接。"
  (let* ((store (open-connection))
         (sources (map vendor-certificate-source certs))
         (items (map (lambda (src)
                       (unless (file-append? src)
                         (error "vendor certificate source is not file-append"
                                src))
                       (cons src (package-derivation store
                                                     (file-append-base src)
                                                     #:graft? #f)))
                     sources)))
    (build-things store (map (compose derivation-file-name cdr) items))
    (map (lambda (item)
           (string-append (derivation->output-path (cdr item))
                          (string-concatenate
                           (file-append-suffix (car item)))))
         items)))

(define (build-variable! keydir work keystore guid var sign-key certs)
  "合并 我们 + vendor + 固件默认值，签名产出 VAR.auth 到 keystore。
VAR 是字符串 \"KEK\" 或 \"db\"，SIGN-KEY 是签名者名（\"PK\"/\"KEK\"）。"
  (let ((pieces
         ;; 1. 我们自己的
         (cons (begin
                (esl-of (string-append keydir "/" var ".crt")
                        (string-append work "/" var "-ours.esl")
                        guid)
                (string-append work "/" var "-ours.esl"))
               ;; 2. vendor 的微软证书（DER → PEM → ESL）
               (append
                (map (lambda (der)
                       (let ((pem (string-append work "/"
                                                 (basename der) ".pem"))
                             (esl (string-append work "/"
                                                 (basename der) ".esl")))
                         (pem-of-der der pem)
                         (esl-of pem esl %ms-owner-guid)
                         esl))
                     (cert-store-paths certs))
                ;; 3. 固件默认值（本来就是 ESL 内容）
                (let ((out (string-append work "/" var "-firmware.esl")))
                  (if (firmware-esl (if (string=? var "KEK")
                                      "KEKDefault"
                                      "dbDefault")
                                    out)
                    (list out)
                    '()))))))
    (let ((combined (string-append work "/" var ".esl")))
      ;; ESL 即列表，直接拼接
      (call-with-output-file combined
                             (lambda (port)
                               (for-each
                                (lambda (piece)
                                  (call-with-input-file piece
                                                        (lambda (in) (sendfile port in (stat:size (stat in))))))
                                pieces)))
      (mkdir-p (string-append keystore "/" var))
      (run "sign-efi-sig-list" "-g" guid
           "-k" (string-append keydir "/" sign-key ".key")
           "-c" (string-append keydir "/" sign-key ".crt")
           var combined
           (string-append keystore "/" var "/" var ".auth"))
      (format #t "~a.auth generated (with ~a certificate entries)~%"
              var (length pieces)))))

(define (main args)
  (let* ((keydir (match (cdr args)
                        (() %default-keydir)
                        ((dir) dir)
                        (_ (format (current-error-port)
                                   "Usage: secure-boot-enroll [keydir]~%")
                           (exit 1))))
         (work (string-append keydir "/keystore/.work"))
         (keystore (string-append keydir "/keystore")))
    (let ((missing (missing-key-files keydir)))
      (unless (null? missing)
        (format (current-error-port)
                "Secure Boot key set is incomplete:~%")
        (for-each
         (lambda (name)
           (format (current-error-port)
                   "  missing ~a/~a~%"
                   keydir name))
         missing)
        (format (current-error-port)
                "Please run tools/secure-boot-keygen.scm first.~%")
        (exit 1)))
    (mkdir-p work)
    
    (let ((guid (command-output "uuidgen")))
      ;; ── PK：只有我们自己 ──
      (esl-of (string-append keydir "/PK.crt")
              (string-append work "/PK.esl") guid)
      (mkdir-p (string-append keystore "/PK"))
      (run "sign-efi-sig-list" "-g" guid
           "-k" (string-append keydir "/PK.key")
           "-c" (string-append keydir "/PK.crt")
           "PK" (string-append work "/PK.esl")
           (string-append keystore "/PK/PK.auth"))
      
      ;; ── KEK 与 db：我们 + 微软 + 固件默认值 ──
      (build-variable! keydir work keystore guid "KEK" "PK"
                       (vendor-certificates-for 'KEK))
      (build-variable! keydir work keystore guid "db" "KEK"
                       (vendor-certificates-for 'db)))
    
    (format #t "~%keystore ready: ~a~%~
               Enrollment (PK written last; writing it enables Secure Boot):~%~
               ~%  sbkeysync --keystore ~a --verbose~%~
               ~%  sbkeysync --keystore ~a --verbose --pk~%"
            keystore keystore keystore)))

(main (command-line))
