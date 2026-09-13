;;; 开发环境：编辑、测试和构建本仓库所需的工具。
;;; 用法：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm
;;;
;;; Blue/Guile 兼容性（2026-09 根因）：bluebox 的 blue 包依赖 guile-3.0
;;; （本频道解析为 3.0.9），而 pinned Guix 的 guix 包依赖
;;; guile-3.0-latest（3.0.11）。Guile 字节码只向后兼容（3.0.11 能读
;;; 3.0.9 字节码，3.0.9 不能读 3.0.11），所以 blue(3.0.9) 加载 3.0.11
;;; 编译的 guix 模块时报 "incompatible bytecode version"。
;;;
;;; 处理：用 package transform 把 blue 重建为 guile@3.0.11（不修改
;;; bluebox 包本体、不复制 package definition）。bluebox 注释里那个
;;; guile-3.0.11 bug 会让 blue 自身的 fallback-chains 回归测试失败
;;; （上游 issue），故跳过 blue 的测试；日常 blue 命令（doctor /
;;; reconfigure / build-os 等）不触及该路径。同一处理见
;;; modules/guixcfg/apps/blue/definition.scm（Home profile 的日常入口）。

(use-modules (gnu packages)
             (guix packages)
             (guix transformations)
             (bluebox packages blue))

(define blue-compatible
  ((options->transformation
    '((with-input . "guile=guile@3.0.11")
      (without-tests . "blue")))
   blue))

(concatenate-manifests
 (list (specifications->manifest
        (list "guile"          ; Scheme 解释器，运行和测试模块
              "git"            ; 版本控制（部署 clean-tree gate）
              "qemu"           ; VM 测试
              "gptfdisk"       ; sgdisk：GPT 分区
              "cryptsetup"     ; LUKS2
              "btrfs-progs"    ; Btrfs 子卷与 swapfile
              "dosfstools"     ; ESP 的 VFAT 格式化
              "coreutils"      ; stty：LUKS 密码输入时关闭终端回显
              "util-linux"))   ; lsblk、findmnt、wipefs（设备探测）
       (packages->manifest (list blue-compatible))))
