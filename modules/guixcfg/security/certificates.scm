;;; 外部 vendor 证书：Secure Boot 兼容信任链（docs/boot.md 第 16.3 节）。
;;;
;;; 信任模型：PK/KEK/db 的私钥全部自有；这里只是公开 CA 证书，
;;; 在注册（enrollment）时合并进固件的 KEK/db，保留硬件兼容性
;;; （Windows Boot Manager、shim、显卡 Option ROM 等）。
;;;
;;; 每张证书是 origin + 固定 sha256：来源可追溯、内容可校验、
;;; 更新时代码 review 友好（docs 设计原则：外部事实固定哈希）。
;;; 固件自带 OEM 证书不进仓库——enrollment 时现读 dbDefault/KEKDefault。

(define-module (guixcfg security certificates)
               #:use-module (guix records)      ; define-record-type*
               #:use-module (guix packages)     ; origin
               #:use-module (guix download)     ; url-fetch
               #:export (<vendor-certificate>
                         vendor-certificate make-vendor-certificate vendor-certificate?
                         vendor-certificate-name
                         vendor-certificate-database
                         vendor-certificate-purpose
                         vendor-certificate-source
                         %vendor-certificates
                         vendor-certificates-for))

(define-record-type* <vendor-certificate>
                     vendor-certificate make-vendor-certificate
                     vendor-certificate?
                     (name     vendor-certificate-name)     ; 符号
                     (database vendor-certificate-database) ; 'db 或 'KEK
                     (purpose  vendor-certificate-purpose)  ; 字符串
                     (source   vendor-certificate-source)) ; <origin>（DER 证书）

(define (ms-cert name db purpose path hash)
  (vendor-certificate
   (name name)
   (database db)
   (purpose purpose)
   (source
    (origin
     (method url-fetch)
     (uri (string-append
           "https://raw.githubusercontent.com/Foxboron/sbctl/master/certs/microsoft/"
           path))
     ;; URL 里的 %20 不能进 derivation 名，显式指定
     (file-name (string-append (symbol->string name) ".der"))
     (sha256 (base32 hash))))))

;;; db：镜像与 EFI 程序的信任链。

(define microsoft-uefi-ca-2011
  (ms-cert 'microsoft-uefi-ca-2011 'db
           "shim 及第三方 UEFI 驱动/程序"
           "db/MicCorUEFCA2011_2011-06-27.der"
           "01w54h03a3f479h8v7wv49a73i2q1bzrnna9c7vm5z2p3ycrpsa8"))

(define microsoft-windows-production-pca-2011
  (ms-cert 'microsoft-windows-production-pca-2011 'db
           "Windows Boot Manager (2011)"
           "db/MicWinProPCA2011_2011-10-19.der"
           "0q8rqzfgsdb9g1mgmj5kckmgql9ww8z438g0gfnqnpm56c3mzsg8"))

(define microsoft-option-rom-uefi-ca-2023
  (ms-cert 'microsoft-option-rom-uefi-ca-2023 'db
           "PCIe/显卡 Option ROM（实机点亮的兼容性关键）"
           "db/microsoft%20option%20rom%20uefi%20ca%202023.der"
           "1wfqm15w241c4r202fiammx5g1q7dl6wxppcawa2hsp6qrj3xgp5"))

(define microsoft-uefi-ca-2023
  (ms-cert 'microsoft-uefi-ca-2023 'db
           "shim 及第三方 UEFI 驱动/程序 (2023)"
           "db/microsoft%20uefi%20ca%202023.der"
           "00frv88xdvvq24r1m74jknyygh4igfm4wmwsszk3zvjv28s4w4pn"))

(define microsoft-windows-uefi-ca-2023
  (ms-cert 'microsoft-windows-uefi-ca-2023 'db
           "Windows Boot Manager (2023)"
           "db/windows%20uefi%20ca%202023.der"
           "0c73k853a7j6r0nk1nlnw4dxs7szyy17dhbppxg1aadcj3m1yvq7"))

;;; KEK：db/dbx 更新的授权链。

(define microsoft-kek-ca-2011
  (ms-cert 'microsoft-kek-ca-2011 'KEK
           "微软生态 db/dbx 更新授权 (2011)"
           "KEK/MicCorKEKCA2011_2011-06-24.der"
           "00x50bc6b7p0jswx1q4gprmzswkrm08cw6id7yxgrkijd98py4d1"))

(define microsoft-kek-2k-ca-2023
  (ms-cert 'microsoft-kek-2k-ca-2023 'KEK
           "微软生态 db/dbx 更新授权 (2023)"
           "KEK/microsoft%20corporation%20kek%202k%20ca%202023.der"
           "17bgmkl9gpf9qf62x3r1spxw9zsakw6x8vcpg9v2iqnskqqg1lrw"))

(define %vendor-certificates
  (list microsoft-uefi-ca-2011
        microsoft-windows-production-pca-2011
        microsoft-option-rom-uefi-ca-2023
        microsoft-uefi-ca-2023
        microsoft-windows-uefi-ca-2023
        microsoft-kek-ca-2011
        microsoft-kek-2k-ca-2023))

(define (vendor-certificates-for database)
  "指定数据库（'db 或 'KEK）的全部 vendor 证书。"
  (filter (lambda (cert)
            (eq? (vendor-certificate-database cert) database))
          %vendor-certificates))
