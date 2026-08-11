;;; 安装环境：LiveCD 中执行磁盘安装所需的工具。
;;; 用法（docs/installation.md 第 30 章）：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm \
;;;     -- configctl install --host vm /dev/vda

(specifications->manifest
 (list "git"
       "gptfdisk"       ; sgdisk
       "cryptsetup"
       "btrfs-progs"
       "dosfstools"
       "ukify"          ; UKI 组装与 Secure Boot 密钥生成（Rosenthal）
       "openssl"        ; 证书格式转换（DER→PEM，secure-boot-enroll 用）
       "sbsigntools"    ; UKI/EFI 签名与固件变量签名（sbsign、sbvarsign）
       "efitools"       ; cert-to-efi-sig-list、efi-updatevar（固件注册）
       "util-linux"))   ; lsblk、findmnt、udevadm、uuidgen 等设备工具
