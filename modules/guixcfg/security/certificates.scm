;;; 外部 vendor 证书：Secure Boot 兼容信任链（docs/architecture/boot.md（Secure Boot））。
;;;
;;; 信任模型：PK/KEK/db 的私钥全部自有；这里只是公开 CA 证书，
;;; 在注册（enrollment）时合并进固件的 KEK/db，保留硬件兼容性
;;; （Windows Boot Manager、shim、显卡 Option ROM 等）。
;;;
;;; 证书来源：virelith 频道的数据包 microsoft-secure-boot-certificates
;;; （(virelith packages secure-boot)）——7 张 DER 在包内以
;;; origin + 固定 sha256 从 Foxboron/sbctl 拉取（docs 设计原则：
;;; 外部事实固定哈希），安装到 share/secure-boot/microsoft/{db,KEK}/。
;;; 本模块只记录"哪张证书进哪个数据库、干什么用"，source 统一
;;; file-append 指向包内文件。
;;; 固件自带 OEM 证书不进仓库——enrollment 时现读 dbDefault/KEKDefault。

(define-module (guixcfg security certificates)
               #:use-module (guix records)      ; define-record-type*
               #:use-module (guix gexp)         ; file-append
               #:use-module (virelith packages secure-boot) ; microsoft-secure-boot-certificates
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
                     (source   vendor-certificate-source)) ; <file-append>（包内 DER）

(define (ms-cert name db purpose path)
  "PATH 是包内 share/secure-boot/microsoft/ 下的相对路径（安装名与
%microsoft-secure-boot-certs 的 install-name 一致；哈希固定于包内）。"
  (vendor-certificate
   (name name)
   (database db)
   (purpose purpose)
   (source (file-append microsoft-secure-boot-certificates
                        (string-append "/share/secure-boot/microsoft/" path)))))

;;; db：镜像与 EFI 程序的信任链。

(define microsoft-uefi-ca-2011
  (ms-cert 'microsoft-uefi-ca-2011 'db
           "shim and third-party UEFI drivers/programs"
           "db/microsoft-uefi-ca-2011.der"))

(define microsoft-windows-production-pca-2011
  (ms-cert 'microsoft-windows-production-pca-2011 'db
           "Windows Boot Manager (2011)"
           "db/microsoft-windows-production-pca-2011.der"))

(define microsoft-option-rom-uefi-ca-2023
  (ms-cert 'microsoft-option-rom-uefi-ca-2023 'db
           "PCIe/GPU Option ROM (compatibility-critical for real hardware)"
           "db/microsoft-option-rom-uefi-ca-2023.der"))

(define microsoft-uefi-ca-2023
  (ms-cert 'microsoft-uefi-ca-2023 'db
           "shim and third-party UEFI drivers/programs (2023)"
           "db/microsoft-uefi-ca-2023.der"))

(define microsoft-windows-uefi-ca-2023
  (ms-cert 'microsoft-windows-uefi-ca-2023 'db
           "Windows Boot Manager (2023)"
           "db/microsoft-windows-uefi-ca-2023.der"))

;;; KEK：db/dbx 更新的授权链。

(define microsoft-kek-ca-2011
  (ms-cert 'microsoft-kek-ca-2011 'KEK
           "Microsoft ecosystem db/dbx update authorization (2011)"
           "KEK/microsoft-kek-ca-2011.der"))

(define microsoft-kek-2k-ca-2023
  (ms-cert 'microsoft-kek-2k-ca-2023 'KEK
           "Microsoft ecosystem db/dbx update authorization (2023)"
           "KEK/microsoft-kek-2k-ca-2023.der"))

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
