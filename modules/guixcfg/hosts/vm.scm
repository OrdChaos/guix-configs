;;; VM 最终 <operating-system> 组装点（docs/project-definition.md 第 21 章）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %os)'

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; dhcpcd-service-type
               #:use-module (gnu packages bash)            ; bash
               #:use-module (guixcfg storage model)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:use-module (guixcfg boot uki-bootloader)  ; uki-bootloader
               #:use-module (guixcfg services ephemeral-root)
               #:use-module (guixcfg system common)
               #:use-module (guixcfg system file-systems)
               #:use-module (guixcfg system packages)
               #:use-module (guixcfg system ssh)       ; secure-ssh-service、ssh-host-key-service
               #:use-module (guixcfg system user-persistence)  ; selected user persistence
               #:use-module (guixcfg home user)        ; %guix-home（挂入 system）
               #:use-module (gnu services guix)        ; guix-home-service-type
               #:use-module (virelith packages tpm2)   ; tpm2-tools-compat（enroll 工具依赖）
               #:export (%vm-storage-policy %vm-services %os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %vm-storage-policy storage:%vm-storage-policy)

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
   ;; 无状态根的用户态服务：启动确认（last-good）与旧 generation 清理
   ;; （docs/storage.md 第 17.4、17.8 节）。
   (ephemeral-root-shepherd-services
    (host-storage-policy-keep-root-generations %vm-storage-policy))
   ;; 基础 session infrastructure（elogind：/run/user、XDG_RUNTIME_DIR、
   ;; PAM session——system/common 拥有）。
   %common-services
   %base-services))

(define %os
  (operating-system
   (host-name "guix-vm")
   (timezone %common-timezone)
   (locale %common-locale)
   
   ;; Limine + UKI + UEFI 直启（docs/boot.md 第 16 章）。
   ;; ESP 部署由 (guixcfg boot uki) 的部署脚本完成。
   (bootloader (bootloader-configuration
                (bootloader uki-bootloader)
                (targets '("/efi"))))
   
   (mapped-devices (cryptroot-mapped-devices))
   
   ;; 无状态根（docs/storage.md 第 17 章）：initrd 启动时按
   ;; @persist-system/root-generations/state.scm 选择/创建 @root-N，
   ;; 挂到 /selected-root 后由 boot-system bind 成系统根。
   (initrd ephemeral-root-initrd)
   (file-systems (append (system-file-systems %ephemeral-root-file-system)
                         ;; selected user persistence（bind mounts，login 前就位）
                         (user-persistence-file-systems "user")
                         %base-file-systems))
   
   (swap-devices %swap-spaces)
   
   (users %vm-users)
   ;; tpm2-tools-compat 显式加入 system profile：tpm2-enroll 工具
   ;; （guix repl tools/tpm2-enroll.scm）依赖
   ;; /run/current-system/profile/bin/tpm2_{pcrread,createprimary,...}，
   ;; 必须来自锁定 Virelith 的 compat 包（docs/boot.md 第 16.4 节）。
   (packages (append (list tpm2-tools-compat) %system-packages))
   (services (append (list (secure-ssh-service)
                           (ssh-host-key-service)
                           (user-persistence-service "user")
                           ;; Guix Home 挂入 system：home-environment 随
                           ;; system generation 构建，boot 时由官方
                           ;; guix-home-service-type 以 user 身份运行其
                           ;; activate（重建 ephemeral $HOME 中的
                           ;; ~/.guix-home 与 dotfile 链接，指向本
                           ;; generation closure 内的 home）。
                           (service guix-home-service-type
                                    `(("user" ,%guix-home))))
                     %vm-services))))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts vm)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/vm.scm /mnt
%os
