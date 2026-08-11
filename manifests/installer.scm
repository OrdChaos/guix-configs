;;; LiveCD 早期磁盘安装环境。
;;;
;;; 这里只包含分区、加密、文件系统和设备探测所需工具。
;;; 必须保持与 UKI / Secure Boot / TPM 工具链解耦：
;;;   keygen 用 manifests/secure-boot-keygen.scm，
;;;   enrollment 用 manifests/secure-boot-enroll.scm。
;;; 用法（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm

(specifications->manifest
 (list "git"
       "gptfdisk"       ; sgdisk
       "cryptsetup"
       "btrfs-progs"
       "dosfstools"
       "util-linux"))   ; lsblk、findmnt、udevadm 等设备工具
