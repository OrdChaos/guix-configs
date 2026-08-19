;;; VM 最终 <operating-system> 组装点（docs/README.md）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %os)'

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; dhcpcd-service-type
               #:use-module (gnu system shadow)            ; account-service-type（折叠 account 列表）
               #:use-module (guixcfg storage model)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:use-module (guixcfg boot uki-bootloader)  ; uki-bootloader
               #:use-module (guixcfg system kernel-platform) ; %kernel、microcode-ephemeral-initrd（M1）
               #:use-module (guixcfg system desktop) ; desktop-services（M2 greetd/niri）
               #:use-module (guixcfg services ephemeral-root)
               #:use-module (guixcfg system common)
               #:use-module (guixcfg system file-systems)
               #:use-module (guixcfg system packages)
               #:use-module (guixcfg system ssh)       ; secure-ssh-service、ssh-host-key-service
               #:use-module (guixcfg system user-persistence)  ; selected user persistence
               #:use-module (guixcfg system readiness) ; boot readiness DAG
               #:use-module (guixcfg system accounts)  ; 纯 Scheme account 数据库投影
               #:use-module (guixcfg users user)       ; %primary-user（结构事实权威源）
               #:use-module (guixcfg home user)        ; %guix-home（挂入 system）
               #:use-module (guixcfg security secrets)  ; runtime secrets 部署机制
               #:use-module (guixcfg hosts vm-secrets)  ; VM secret inventory（host-owned）
               #:use-module (gnu services guix)        ; guix-home-service-type
               #:use-module (virelith packages tpm2)   ; tpm2-tools-compat（enroll 工具依赖）
               #:use-module (srfi srfi-1)              ; remove
               #:export (%vm-storage-policy %vm-services %os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %vm-storage-policy storage:%vm-storage-policy)

;; Primary user 来自 (guixcfg users user) 的 %primary-user（结构事实的
;; 唯一来源：username/uid/groups/shell/home）。密码 hash 不在此处——
;; user-account password 为 #f，hash 由 install secret 在 LUKS 建立后
;; 注入目标 shadow（ephemeral root 下 account activation 复用既有
;; shadow 条目，跨 boot/reconfigure 保留；docs/architecture/secrets.md）。
(define %vm-users
  (list (primary-user-account)))

(define %vm-services
  (append
   (list ;; QEMU user-mode 网络需要 DHCP（当前 master 中 dhcp-client-service-type
    ;; 已由 dhcpcd-service-type 取代）。
         (service dhcpcd-service-type))
   ;; 无状态根的用户态服务：启动确认（last-good）与旧 generation 清理
   ;; （docs/architecture/storage.md，Root generation 一节）。
   (ephemeral-root-shepherd-services
    (host-storage-policy-keep-root-generations %vm-storage-policy))
   ;; 基础 session infrastructure（elogind：/run/user、XDG_RUNTIME_DIR、
   ;; PAM session——system/common 拥有）。
   %common-services
   ;; TTY login prompt 的强语义（Section 57）：login: 出现 =
   ;; interactive-session-ready 已过——mingetty 延迟到 barrier 之后；
   ;; PAM gate 是 correctness fallback（新增 frontend 漏加
   ;; requirement 也绕不过 readiness policy）。
   ;; M2：tty1 归 greetd（desktop-services）；其余 mingetty（tty2-6）
   ;; 是普通 tty fallback（desktop 故障仍可登录；两者都 gated by
   ;; interactive-session-ready）。tty1 的 mingetty 从 %base-services
   ;; 移除（与 greetd 冲突）。
   (let* ((gated (modify-services %base-services
                                  (mingetty-service-type config =>
                                                         (mingetty-configuration
                                                          (inherit config)
                                                          (shepherd-requirement
                                                           (append (mingetty-configuration-shepherd-requirement config)
                                                                   '(interactive-session-ready)))))))
          (no-tty1 (remove (lambda (svc)
                             (and (eq? (service-kind svc) mingetty-service-type)
                                  (string=? (mingetty-configuration-tty
                                             (service-value svc))
                                            "tty1")))
                           gated)))
     (append no-tty1
             ;; M2 Wayland desktop：greetd（tty1，gated）+ niri session
             ;; （docs/architecture/graphics.md）。
             desktop-services))))

;; 完整 user services（不含 account-databases 投影本身）。OS 的全部
;; 业务服务都在这一个列表里——用于 (a) 折叠完整 account 列表，
;; (b) 组装最终 %os。
(define %vm-user-services
  (append
   (list (secure-ssh-service)
         (ssh-host-key-service)
         (user-persistence-service
          (user-profile-name %primary-user))
         ;; 声明式 runtime secrets（boot 时 root 解密到
         ;; /run/guixcfg-secrets；docs/architecture/secrets.md）
         (secrets-deploy-service
          %vm-secrets (user-profile-name %primary-user))
         ;; account databases 投影（唯一 writer，含 persistent credential
         ;; 内联注入）之后的只读验证：account-state-ready 的 provision 端。
         (account-databases-verify-service
          (user-profile-name %primary-user))
         ;; Guix Home 挂入 system：home-environment 随 system generation
         ;; 构建，boot 时由官方 guix-home-service-type 以 user 身份运行
         ;; 其 activate（重建 ephemeral $HOME 中的 ~/.guix-home 与
         ;; dotfile 链接，指向本 generation closure 内的 home）。
         (service guix-home-service-type
                  `((,(user-profile-name %primary-user)
                     ,%guix-home))))
   (append %vm-services
           ;; boot readiness DAG（capability 链；login gate 的开启端在
           ;; interactive-session-ready）
           (readiness-services 'guix-home-user)
           ;; login gate：activation 关闭 + PAM gate（login/sshd account
           ;; 段 pam_nologin）
           (login-gate-services))))

;; 基础 OS：与最终 %os 完全相同，只是不含 account-databases 投影。
;; 仅用于折叠 account 列表；真正启动用 %os。
(define %os-without-account-databases
  (operating-system
   (host-name "guix-vm")
   (timezone %common-timezone)
   (locale %common-locale)
   
   ;; Limine + UKI + UEFI 直启（docs/architecture/boot.md）。
   ;; ESP 部署由 (guixcfg boot uki) 的部署脚本完成。
   (bootloader (bootloader-configuration
                (bootloader uki-bootloader)
                (targets '("/efi"))))
   
   (mapped-devices (cryptroot-mapped-devices))
   
   ;; Kernel platform（M1）：Nonguix standard Linux + linux-firmware +
   ;; Intel microcode。kernel/firmware/microcode 的唯一权威定义在
   ;; (guixcfg system kernel-platform)（docs/architecture/boot.md）。
   (kernel %kernel)
   (firmware (list %kernel-firmware))
   
   ;; 无状态根（docs/architecture/storage.md）：initrd 启动时按
   ;; @persist-system/root-generations/state.scm 选择/创建 @root-N，
   ;; 挂到 /selected-root 后由 boot-system bind 成系统根。
   ;; microcode-ephemeral-initrd = microcode cpio 拼接 custom initrd
   ;; （composition，custom initrd 仍是 authoritative payload）。
   (initrd microcode-ephemeral-initrd)
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
   ;; 必须来自锁定 Virelith 的 compat 包（docs/architecture/boot.md（TPM2））。
   (packages (append (list tpm2-tools-compat) %system-packages))
   (services %vm-user-services)))

;; 完整 account 列表 = account-service-type 的 folded value（root +
;; 声明的 users/groups + 全部服务贡献的 account，如 guixbuilder01-10、
;; sshd、messagebus、polkitd）。account-databases 投影自身不扩展
;; account-service-type，因此含不含它对折叠结果无影响——先在一个
;; 不含它的 probe OS 上折叠，再组装最终 %os（避免自引用）。
(define %vm-accounts+groups
  (service-value
   (fold-services (operating-system-services
                   %os-without-account-databases)
                  #:target-type account-service-type)))

;; 最终 OS：基础 OS + account-databases 纯 Scheme 投影（修复上游
;; activate-users+groups 的 FFI flock 在 boot 环境失败导致
;; /etc/passwd|group|shadow 为空、readiness 卡死的问题）。
;; 投影放在 user-services 列表末尾：fold-services 反转处理顺序，
;; 列表末尾 = user activation 中最早运行（紧随 essential 的
;; account 步骤之后），保证后续 user activation（如 user-persistence
;; 的 getpw）能看到完整数据库。
(define %os
  (operating-system
   (inherit %os-without-account-databases)
   (services (append (operating-system-user-services
                      %os-without-account-databases)
                     (list (account-databases-service
                            %vm-accounts+groups))))))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts vm)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/vm.scm /mnt
%os
