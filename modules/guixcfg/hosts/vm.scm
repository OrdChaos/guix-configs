;;; VM 最终 <operating-system> 组装点（docs/project-definition.md 第 21 章）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %os)'

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; dhcpcd-service-type
               #:use-module (gnu packages bash)            ; bash
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg system common)
               #:use-module (guixcfg system file-systems)
               #:use-module (guixcfg system packages)
               #:export (%vm-storage-policy %os))

;; VM 存储 policy（docs/storage.md 第 20.2 节）：
;; QEMU 测试盘，容量小，不绑定具体 by-id（安装时必须显式传入设备）。
(define %vm-storage-policy
  (host-storage-policy
   (name 'vm)
   (esp-size (gib 2))
   (min-disk-size (gib 20))
   (swapfile-size (gib 4))
   (keep-root-generations 3)))

;; VM 测试账号。密码哈希对应明文 guix-vm，仅用于测试 VM；
;; 真实用户的密码材料走 age secret（docs/secrets.md 第 15 章）。
(define %vm-users
  (list (user-account
         (name "user")
         (comment "VM test user")
         (group "users")
         (supplementary-groups '("wheel" "netdev"))
         (shell (file-append bash "/bin/bash"))
         (home-directory "/home/user")
         (password "$6$guixconfigs$ZfB2boEo/DBJKS.0A9BQkUfD4JU8P9Y8yuC/dU71yWNDC3NRu2DByReuIcdygDGv2JzIWLozjr7axXnvGmHs7."))))

(define %vm-services
  (append
   (list ;; QEMU user-mode 网络需要 DHCP（当前 master 中 dhcp-client-service-type
    ;; 已由 dhcpcd-service-type 取代）。
         (service dhcpcd-service-type))
   %base-services))

(define %os
  (operating-system
   (host-name "guix-vm")
   (timezone %common-timezone)
   (locale %common-locale)
   
   ;; 阶段 3 先用 GRUB-EFI 跑通启动链；UKI/Limine 在阶段 5 替换（docs/boot.md）。
   (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/efi"))))
   
   (mapped-devices %cryptroot-mapped-devices)
   
   ;; root 暂时固定为 @root-installing；
   ;; 阶段 4 引入 root generation 后由启动流程选择 @root-N。
   (file-systems (append (system-file-systems %root-installing-name)
                         %base-file-systems))
   
   (swap-devices %swap-spaces)
   
   (users %vm-users)
   (packages %system-packages)
   (services %vm-services)))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts vm)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/vm.scm /mnt
%os
