;;; 开发环境：编辑、测试和构建本仓库所需的工具。
;;; 用法：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm

(specifications->manifest
 (list "guile"          ; Scheme 解释器，运行和测试模块
       "git"            ; 版本控制（部署快照依赖 git archive）
       "qemu"           ; VM 测试（阶段 2 起）
       "parted"         ; GPT 分区（阶段 2）
       "cryptsetup"     ; LUKS2（阶段 2）
       "btrfs-progs"    ; Btrfs 子卷与 swapfile（阶段 2）
       "dosfstools"))   ; ESP 的 VFAT 格式化（阶段 2）
