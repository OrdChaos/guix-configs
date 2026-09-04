;;; Host composition helper（docs/reference/repository-layout.md）。
;;;
;;; VM 与 Laptop 的 <operating-system> 组装算法在归一化后高度重合
;;; （services 列表 / user-services 列表 / 基础 OS / account fold +
;;; 最终 OS 两阶段组装逐项同源）。本模块提取这份共享 composition
;;; algorithm——不是 module system：无 dependency solver、无
;;; priority/override/fixpoint、无自动 host 扫描、无巨型 <host>
;;; record；只有四个窄构造函数，host 显式传入真实差异：
;;;
;;;   network services          VM：NM 空 requirement；Laptop：NM
;;;                             默认 + wpa-supplicant
;;;   storage policy            keep-root-generations 参数
;;;   persistence rules         Flatpak 平台规则共享（2026-09：从
;;;                             VM-only 提升到 common——所有 host 都用）
;;;   secrets composition       VM 含测试 sentinel，Laptop 不含
;;;   home environment          %guix-home vs %laptop-guix-home
;;;   final OS transformation   Laptop：nvidia-system-transformation；
;;;                             VM：identity
;;;
;;; 留在 host 模块的 policy：storage policy 再导出、host 名、
;;; 网络服务实例、secrets inventory、bind file-system 列表、Home/
;;; variant selection、NVIDIA/PRIME capability。%primary-user 引用
;;; 留在 common（共享结构事实，不是 inventory）。
;;;
;;; 枚举约束：deploy.scm 的 host-ids-in-directory 把 hosts/*.scm
;;; 的 stem 当 host ID——本文件经 %host-helper-file-stems 显式排除
;;; （见 (guixcfg system deploy)）。

(define-module (guixcfg hosts common)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services base)            ; mingetty-service-type、guix-service-type、modify-services
               #:use-module (gnu services networking)      ; network-manager-service-type
               #:use-module (gnu system shadow)            ; account-service-type（折叠 account 列表）
               #:use-module (gnu services guix)            ; guix-home-service-type
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:use-module (guixcfg boot layout)          ; %esp-mount-point
               #:use-module (guixcfg boot uki-bootloader)  ; uki-bootloader
               #:use-module (guixcfg system kernel-platform) ; %kernel、microcode-ephemeral-initrd（M1）
               #:use-module (guixcfg system desktop)       ; desktop-services（M2 greetd/niri）
               #:use-module (guixcfg services ephemeral-root)
               #:use-module (guixcfg system common)
               #:use-module (guixcfg system file-systems)
               #:use-module (guixcfg system packages)
               #:use-module (guixcfg system ssh)       ; secure-ssh-service、ssh-host-key-service
               #:use-module (guixcfg system user-persistence)  ; selected user persistence
               #:use-module (guixcfg system readiness) ; boot readiness DAG + login gate
               #:use-module (guixcfg system accounts)  ; 纯 Scheme account 数据库投影
               #:use-module (guixcfg users user)       ; %primary-user（结构事实权威源）
               #:use-module (guixcfg security secrets) ; runtime secrets 部署机制
               #:use-module (guixcfg apps registry)    ; %applications（secret composition root）
               #:use-module (guixcfg apps model)       ; applications-secrets、applications-system-services
               #:use-module (guixcfg system application-persistence) ; application persistence generic executor
               #:use-module (guixcfg system mount-metadata) ; gvfs-mount-metadata-service
               #:use-module (guixcfg system mihomo service) ; mihomo-service（透明代理）
               #:use-module (guixcfg system dns ownership) ; system-dns-etc-service（DNS ownership）
               #:use-module (guixcfg system dns smartdns) ; smartdns-service（system resolver）
               #:use-module (guixcfg system machine-state-persistence) ; machine-state bind（mihomo providers）
               #:use-module (guixcfg system machine-identity) ; /etc/machine-id 持久化（先于 D-Bus activation）
               #:use-module (guixcfg system noctalia-greeter) ; noctalia-greeter machine-state bind + 系统集成
               #:use-module (guixcfg system sudo policy) ; %sudoers-file（Defaults 声明：lecture/passprompt）
               #:use-module (guixcfg system profile policy) ; %system-profile（/etc/profile ownership）
               #:use-module (guixcfg flatpak service) ; flatpak-persistence-rules（installation + 每 selected app，所有 host 共享）
               #:use-module (virelith packages tpm2)   ; tpm2-tools-compat（enroll 工具依赖）
               #:use-module (srfi srfi-1)              ; remove
               #:export (make-host-services
                         make-host-user-services
                         make-base-host-operating-system
                         make-host-operating-system
                         ;; Flatpak 应用 persistence（共享结构事实：
                         ;; 2026-09 从 VM-only 提升到 common 层）
                         host-application-persistence-rules
                         host-persistent-mount-file-systems))

;;; ── 共享 application persistence 事实（Flatpak 是所有 host 的结构
;;; 事实，2026-09 从 VM-only 提升到 common 层——不再由 host 各自
;;; append：application rules + Flatpak 平台规则 + HOME persistence
;;; bind 列表在 common 单一构造，host 只消费）。

(define (host-application-persistence-rules)
  "全部 application persistence 规则：applications + Flatpak 平台
（installation + 每 selected app）。所有 host 共享。"
  (append (applications-persistence %applications)
          (flatpak-persistence-rules)))

(define (host-persistent-mount-file-systems)
  "HOME persistence bind 列表（user data + app state，含 Flatpak）。
gvfs-mount-metadata 服务与 file-systems 字段共用同一列表。"
  (append (user-persistence-file-systems
           (user-profile-name %primary-user))
          (application-persistence-file-systems
           (host-application-persistence-rules)
           (user-profile-name %primary-user))))

;;; ── TTY login prompt 的强语义（docs/architecture/accounts-sessions.md）
;;; login: 出现 = interactive-session-ready 已过——mingetty 延迟到
;;; barrier 之后；PAM gate 是 correctness fallback。tty1 归 greetd
;;; （desktop-services）；其余 mingetty（tty2-6）是普通 tty fallback
;;; （两者都 gated by interactive-session-ready）。tty1 的 mingetty
;;; 从 %base-services 移除（与 greetd 冲突）；guix-daemon 实例由
;;; %common-services 显式声明（tmpdir=/var/tmp，本地构建空间政策），
;;; 移除 %base-services 默认实例避免同类型双实例（fold 报错）。
(define (host-tty-services)
  (let* ((gated (modify-services %base-services
                                 (mingetty-service-type config =>
                                                        (mingetty-configuration
                                                         (inherit config)
                                                         (shepherd-requirement
                                                          (append (mingetty-configuration-shepherd-requirement config)
                                                                  '(interactive-session-ready)))))
                                 (delete guix-service-type)))
         (no-tty1 (remove (lambda (svc)
                            (and (eq? (service-kind svc) mingetty-service-type)
                                 (string=? (mingetty-configuration-tty
                                            (service-value svc))
                                           "tty1")))
                          gated)))
    no-tty1))

(define* (make-host-services #:key
                             (network-services '())
                             keep-root-generations
                             persistent-mount-file-systems)
  "共享 system services 列表。NETWORK-SERVICES 是 host 的网络服务
  头（NetworkManager 配置 + 可选 wpa-supplicant，排在 DNS ownership
  之前）；KEEP-ROOT-GENERATIONS 是 storage policy 的 keep 数；
  PERSISTENT-MOUNT-FILE-SYSTEMS 是 HOME persistence bind 列表
  （gvfs-mount-metadata 与 file-systems 字段共用）。"
  (append
   (append network-services
           (list ;; 系统 DNS ownership（docs/architecture/dns.md）。
            (system-dns-etc-service)
            ;; SmartDNS：唯一 system resolver。
            (smartdns-service)
            ;; GVfs 桌面 metadata（x-gvfs-hide/x-gvfs-trash → utab）。
            (gvfs-mount-metadata-service persistent-mount-file-systems)
            ;; Mihomo 系统透明代理（docs/architecture/mihomo.md）。
            (mihomo-service)))
   ;; 无状态根的用户态服务：登录确认 + 旧 generation 清理。
   (ephemeral-root-services keep-root-generations)
   ;; 基础 session infrastructure（elogind——system/common 拥有）。
   %common-services
   ;; applications 的 system services（composition root 契约保留）。
   (applications-system-services %applications)
   ;; TTY 强语义（mingetty gated + 无 tty1）。
   (host-tty-services)
   ;; M2 Wayland desktop：greetd（tty1，gated）+ niri session。
   desktop-services))

(define* (make-host-user-services #:key
                                  system-services
                                  (application-persistence-rules
                                   (host-application-persistence-rules))
                                  secrets
                                  home-environment)
  "共享 user services 列表（不含 account-databases 投影本身）。
SYSTEM-SERVICES 是 host 的 system services 列表（make-host-services
的产物）；APPLICATION-PERSISTENCE-RULES 默认 = 全部 application +
Flatpak 平台规则（host-application-persistence-rules，所有 host
共享）；SECRETS 是全部声明式 secrets（host 的 inventory：测试
sentinel + mihomo + applications）；HOME-ENVIRONMENT 是挂入 system
的 Guix Home。"
  (append
   (list (secure-ssh-service)
         (ssh-host-key-service)
         (user-persistence-service
          (user-profile-name %primary-user))
         ;; application persistence（generic executor）。
         (application-persistence-service
          application-persistence-rules
          (user-profile-name %primary-user))
         ;; machine-state persistence（root-owned system state）。
         (machine-state-persistence-service
          (list %mihomo-data-persistence-rule
                %noctalia-greeter-persistence-rule))
         ;; noctalia-greeter persistence backing 的 owner/mode
         ;; （activation 先于 file-systems 挂载，与 channel
         ;; activation 幂等无冲突）。
         (simple-service 'noctalia-greeter-backing-ownership
                         activation-service-type
                         (noctalia-greeter-backing-ownership-activation))
         ;; 声明式 runtime secrets（按 readiness domain 分区 →
         ;; 两个 generic publisher 实例）。
         (secrets-deploy-service
          (login-critical-secrets secrets)
          (user-profile-name %primary-user))
         (secrets-ordinary-deploy-service
          (ordinary-secrets secrets)
          (user-profile-name %primary-user))
         ;; account databases 投影之后的只读验证。
         (account-databases-verify-service
          (user-profile-name %primary-user))
         ;; Guix Home 挂入 system（boot 时官方 guix-home-service-type
         ;; 以 user 身份 activate）。
         (service guix-home-service-type
                  `((,(user-profile-name %primary-user)
                     ,home-environment))))
   (append system-services
           ;; boot readiness DAG（capability 链；login gate 的开启端在
           ;; interactive-session-ready）。
           (readiness-services
            (string->symbol
             (string-append "guix-home-"
                            (user-profile-name %primary-user))))
           ;; login gate：activation 关闭 + PAM gate。
           (login-gate-services))))

(define* (make-base-host-operating-system #:key
                                          host-name
                                          persistent-mount-file-systems
                                          mihomo-machine-state-file-systems
                                          noctalia-greeter-machine-state-file-systems
                                          user-services)
  "基础 OS：与最终 OS 完全相同，只是不含 account-databases 投影与
final transformation。仅用于折叠 account 列表；真正启动用
make-host-operating-system 的产物。"
  (operating-system
   (host-name host-name)
   (timezone %common-timezone)
   (locale %common-locale)

   ;; sudo 机器策略：lecture/passprompt Defaults（guixcfg system sudo policy）。
   (sudoers-file %sudoers-file)

   ;; Limine + UKI + UEFI 直启（docs/architecture/boot.md）。
   (bootloader (bootloader-configuration
                (bootloader uki-bootloader)
                (targets (list %esp-mount-point))))

   (mapped-devices (cryptroot-mapped-devices))

   ;; Kernel platform（M1）：Nonguix standard Linux + linux-firmware +
   ;; Intel microcode（docs/architecture/boot.md）。
   (kernel %kernel)
   (firmware (list %kernel-firmware))

   ;; 无状态根（docs/architecture/storage.md）。
   (initrd microcode-ephemeral-initrd)
   (file-systems (append (system-file-systems %ephemeral-root-file-system)
                         ;; selected user persistence（bind mounts，登录前就位）
                         persistent-mount-file-systems
                         ;; machine-state binds（root-owned / greeter-owned）
                         mihomo-machine-state-file-systems
                         noctalia-greeter-machine-state-file-systems
                         %base-file-systems))

   (swap-devices %swap-spaces)

   (users (list (primary-user-account)))
   ;; tpm2-tools-compat 显式加入 system profile：tpm2-enroll 工具
   ;; 依赖 /run/current-system/profile/bin/tpm2_*，必须来自锁定
   ;; Virelith 的 compat 包（docs/architecture/boot.md（TPM2））。
   (packages (append (list tpm2-tools-compat) %system-packages))
   (services user-services)))

(define* (make-host-operating-system base-os
                                     #:key
                                     (final-transformation identity))
  "完整 account 列表 = account-service-type 的 folded value。
account-databases 投影自身不扩展 account-service-type，因此先在
不含它的 BASE-OS 上折叠，再组装最终 OS（避免自引用）。投影放在
user-services 列表末尾（fold-services 反转处理顺序 = user
activation 中最早运行），machine-identity 紧随其后（先于 D-Bus
activation 的 dbus-uuidgen）——docs/architecture/persistence.md
（Machine identity）。FINAL-TRANSFORMATION 是最后的 OS 变换
（Laptop：nvidia-system-transformation；VM：identity）。"
  (let ((accounts+groups
         (service-value
          (fold-services (operating-system-services base-os)
                         #:target-type account-service-type))))
    (final-transformation
     (operating-system
      (inherit base-os)
      (services (append (operating-system-user-services base-os)
                        (list (machine-identity-service)
                              (account-databases-service
                               accounts+groups))))
      ;; /etc/profile ownership：system 只激活 system profile /
      ;; 用户 guix-profile / guix current；Guix Home 激活唯一归
      ;; home（~/.profile → setup-environment）——删除 pinned 模板
      ;; user-profile loop 里的 guix-home 条目（guixcfg system
      ;; profile，2026-09 登录链审计）。etc-service 在 essential
      ;; services 里（operating-system-essential-services），
      ;; 不在 user services——在此替换其 value。
      (essential-services
       (modify-services (operating-system-essential-services base-os)
         (etc-service-type entries =>
           (system-profile-etc-entries entries))))))))
