;;; 开发环境：编辑、测试和构建本仓库所需的工具。
;;; 用法：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm

(specifications->manifest
 (list "guile"          ; Scheme 解释器，运行和测试模块
       "git"            ; 版本控制（部署快照依赖 git archive）
       "qemu"           ; VM 测试（阶段 2 起）
       "gptfdisk"       ; sgdisk：GPT 分区（阶段 2）
       "cryptsetup"     ; LUKS2（阶段 2）
       "btrfs-progs"    ; Btrfs 子卷与 swapfile（阶段 2）
       "dosfstools"     ; ESP 的 VFAT 格式化（阶段 2）
       "coreutils"      ; stty：LUKS 密码输入时关闭终端回显（阶段 2）
       "util-linux"))   ; lsblk、findmnt、wipefs（设备探测，阶段 2）
