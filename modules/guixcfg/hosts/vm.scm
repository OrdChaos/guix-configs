;;; VM 最终 <operating-system> 组装点（docs/project-definition.md 第 21 章）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %os)'

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; dhcpcd-service-type
               #:use-module (gnu services ssh)             ; openssh-service-type
               #:use-module (gnu services base)            ; mingetty-service-type、mingetty-configuration
               #:use-module (gnu packages bash)            ; bash
               #:use-module (guixcfg security tpm2 packages) ; tpm2-tools-compat
               #:use-module (gnu packages hardware)        ; tpm2-tools（T3 场景在 VM 内读取 PCR7）
               #:use-module (gnu packages package-management) ; guix（VM 内运行仓库工具链）
               #:use-module (guix gexp)                  ; local-file
               #:use-module (guixcfg storage model)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:use-module (guixcfg boot uki-bootloader)  ; uki-bootloader
               #:use-module (guixcfg services ephemeral-root)
               #:use-module (guixcfg system common)
               #:use-module (guixcfg system file-systems)
               #:use-module (guixcfg system packages)
               #:export (%vm-storage-policy %os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %vm-storage-policy storage:%vm-storage-policy)

;; VM 测试账号。密码哈希对应明文 guix-vm，仅用于测试 VM；
;; 真实用户的密码材料走 age secret（docs/secrets.md 第 15 章）。
(define %vm-users
  (cons (user-account
         (name "root")
         (comment "T3 test root")
         (group "root")
         (shell (file-append bash "/bin/bash"))
         (home-directory "/root")
         (password "$6$PLZmfXnlX.NPoslT$8l/LjqcwElCDRi7oRnyp13NKV1LY83jJNl.sLwIfzhHh/xyst9XH05QiGYA1Uyc15vQ9dzyneq2YKKignmMMd1"))
        (list (user-account
               (name "user")
               (comment "VM test user")
               (group "users")
               (supplementary-groups '("wheel" "netdev"))
               (shell (file-append bash "/bin/bash"))
               (home-directory "/home/user")
               (password "$6$guixconfigs$ZfB2boEo/DBJKS.0A9BQkUfD4JU8P9Y8yuC/dU71yWNDC3NRu2DByReuIcdygDGv2JzIWLozjr7axXnvGmHs7.")))))

(define %vm-services
  (append
   (list ;; QEMU user-mode 网络需要 DHCP（当前 master 中 dhcp-client-service-type
    ;; 已由 dhcpcd-service-type 取代）。
         (service dhcpcd-service-type)
         ;; ttyS0 串口登录（T3 场景 harness 经串口交互；root 自动登录
         ;; 仅测试 VM——正式 laptop host 不配置）。
         ;; 注意：必须用 agetty 而非 mingetty——%base-services 内置的
         ;; agetty（tty #f 自动探测）会同时尝试 ttyS0，与 mingetty
         ;; 竞争导致会话周期性被杀；agetty 显式占用后自动模式会跳过。
         (service agetty-service-type
                  (agetty-configuration
                   (tty "ttyS0")
                   (term "vt100")
                   (auto-login "root")))
         ;; SSH（T3 harness 经 hostfwd 2222→22 执行系统内命令——
         ;; 串口 getty 会话在注入输入时不稳定，实测）；
         ;; root 密码仅测试 VM。
         (service openssh-service-type
                  (openssh-configuration
                   (permit-root-login #t)
                   ;; T3 harness 的 SSH 公钥（vms/t3/ssh/id_ed25519.pub）
                   (authorized-keys
                    `(("root"
                       ,(local-file
                         "/home/ordchaos/Projects/guix-configs/vms/t3/ssh/id_ed25519.pub")))))))
   ;; 无状态根的用户态服务：启动确认（last-good）与旧 generation 清理
   ;; （docs/storage.md 第 17.4、17.8 节）。
   (ephemeral-root-shepherd-services
    (host-storage-policy-keep-root-generations %vm-storage-policy))
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
                         %base-file-systems))
   
   (swap-devices %swap-spaces)
   
   (users %vm-users)
   ;; guix/tpm2-tools：T3 在 VM 内执行 enroll、sbkeysync、PCR7 读取
   ;; （tpm2-tools 已在 initrd 闭包；这里放进 profile 供用户态使用）。
   ;; tpm2-tools-compat：tpm2-tss 3.0.3 + openssl 3.5 的 HMAC 兼容修复
   ;; （(guixcfg security tpm2 packages)）。
   (packages (append (list guix tpm2-tools-compat) %system-packages))
   (services %vm-services)))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts vm)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/vm.scm /mnt
%os
