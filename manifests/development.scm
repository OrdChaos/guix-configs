;;; 开发环境：编辑、测试和构建本仓库所需的工具。
;;; 用法：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm

(specifications->manifest
 (list "guile"          ; Scheme 解释器，运行和测试模块
       "blue"           ; BLUE 编排工具（blueprint.scm 的运行器；bluebox 频道）
       "git"            ; 版本控制（部署 clean-tree gate）
       "qemu"           ; VM 测试
       "gptfdisk"       ; sgdisk：GPT 分区
       "cryptsetup"     ; LUKS2
       "btrfs-progs"    ; Btrfs 子卷与 swapfile
       "dosfstools"     ; ESP 的 VFAT 格式化
       "coreutils"      ; stty：LUKS 密码输入时关闭终端回显
       "util-linux"))   ; lsblk、findmnt、wipefs（设备探测）
