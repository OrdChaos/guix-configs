;;; Secure Boot 固件注册材料构建环境。
;;;
;;; 仅用于生成 ESL/AUTH、读取固件默认变量以及执行 sbkeysync。
;;; 不用于磁盘安装，也不用于密钥生成。

(specifications->manifest
 (list "openssl"      ; 微软 DER → PEM
       "efitools"     ; cert-to-efi-sig-list、efi-readvar、efi-updatevar
       "sbsigntools"  ; sign-efi-sig-list、sbkeysync
       "util-linux")) ; uuidgen
