;;; VM 最终 <operating-system> 组装点（docs/project-definition.md 第 21 章）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %os)'

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; dhcpcd-service-type
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
               #:use-module (guixcfg users user)       ; %primary-user（结构事实权威源）
               #:use-module (guixcfg home user)        ; %guix-home（挂入 system）
               #:use-module (guixcfg security secrets)  ; runtime secrets 部署
               #:use-module (gnu services guix)        ; guix-home-service-type
               #:use-module (virelith packages tpm2)   ; tpm2-tools-compat（enroll 工具依赖）
               #:export (%vm-storage-policy %vm-services %os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %vm-storage-policy storage:%vm-storage-policy)

;; Primary user 来自 (guixcfg users user) 的 %primary-user（结构事实的
;; 唯一来源：username/uid/groups/shell/home）。密码 hash 不在此处——
;; user-account password 为 #f，hash 由 install secret 在 LUKS 建立后
;; 注入目标 shadow（ephemeral root 下 account activation 复用既有
;; shadow 条目，跨 boot/reconfigure 保留；docs/secrets.md）。
(define %vm-users
  (list (primary-user-account)))

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
                         (user-persistence-file-systems
                          (user-profile-name %primary-user))
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
                           (user-persistence-service
                            (user-profile-name %primary-user))
                           ;; 声明式 runtime secrets（boot 时 root 解密到
                           ;; /run/guixcfg-secrets；docs/secrets.md）
                           (secrets-deploy-service
                            %vm-secrets (user-profile-name %primary-user))
                           ;; 用户密码 hash 注入（install secret →
                           ;; ephemeral /etc/shadow，login 前）
                           (password-inject-service
                            (user-profile-name %primary-user)
                            "secrets/install/user-password.hash.age")
                           ;; Guix Home 挂入 system：home-environment 随
                           ;; system generation 构建，boot 时由官方
                           ;; guix-home-service-type 以 user 身份运行其
                           ;; activate（重建 ephemeral $HOME 中的
                           ;; ~/.guix-home 与 dotfile 链接，指向本
                           ;; generation closure 内的 home）。
                           (service guix-home-service-type
                                    `((,(user-profile-name %primary-user)
                                       ,%guix-home))))
                     %vm-services))))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts vm)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/vm.scm /mnt
%os
