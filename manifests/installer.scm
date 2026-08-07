;;; 安装环境：LiveCD 中执行磁盘安装所需的工具。
;;; 用法（docs/installation.md 第 30 章）：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm \
;;;     -- configctl install --host vm /dev/vda

(specifications->manifest
 (list "git"
       "parted"
       "cryptsetup"
       "btrfs-progs"
       "dosfstools"
       "util-linux"))   ; lsblk、wipefs、udevadm 等设备工具
