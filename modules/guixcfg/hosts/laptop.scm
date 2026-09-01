;;; Laptop 组装点（docs/README.md）。Host 负责组合硬件、存储 policy、
;;; boot 配置和服务。
;;;
;;; Host 是策略/选择层（inventory = facts / host = policy+selection /
;;; application = resource ownership+behavior / composition =
;;; resolution+assembly；docs/architecture/applications.md
;;; （Host-agnostic boundary））：对 application 只做 logical
;;; configuration variant selection——本模块不知道 variant 背后的
;;; 文件、目标路径或 source 位置（那些由 application 自己声明，
;;; generic (guixcfg apps selection) 解析）。application 层不读取
;;; 本模块，依赖方向保持 application ← host。
;;;
;;; 本模块 = home 组合 seam + 完整 <operating-system> 组装：
;;;   %laptop-application-configuration-selections：logical selection
;;;   %laptop-guix-home：(guix-home #:application-configuration-selections ...)
;;;   %laptop-os：最终 operating-system，与 VM 组装同构——kernel/
;;;     firmware/initrd 复用 (guixcfg system kernel-platform)，boot/
;;;     UKI 复用 (guixcfg boot *)，服务复用 common/desktop/network/
;;;     persistence/secrets/readiness 共享模块；host 层只做差异
;;;     （实机网络 = NetworkManager 默认配置 + wpa-supplicant；
;;;     无 VM 测试 secrets；storage policy 用 laptop 参数）。
;;;     最后一步套 NVIDIA adapter（(guixcfg system graphics nvidia)）
;;;     ——per-machine optional capability，VM 侧零贡献。
;;;
;;; 与 VM 的差异（其余组装逐项同源，见 (guixcfg hosts vm)）：
;;;   1. 网络：NetworkManager 保留默认 shepherd-requirement
;;;      '(wireless-daemon)，并显式实例化 wpa-supplicant-service-type
;;;      （pinned Guix 的 network-manager-service-type 不会自动
;;;      实例化 wpa-supplicant——VM 无 WiFi 因而把 requirement 置空）；
;;;   2. secrets：无 %vm-test-secrets（那是 VM 测试机的机制 sentinel）；
;;;   3. guix-home：%laptop-guix-home（含 niri 'laptop variant
;;;      selection，iGPU compositor + NVIDIA offload 的机器事实；
;;;      laptop-only host capability %prime-run-wrapper）；
;;;   4. NVIDIA：最终 %laptop-os 套 nvidia-system-transformation（open kernel
;;;      module + dynamic boost；kernel 不被替换）。
;;;
;;; 构建（需要 machine facts，见 (guixcfg system file-systems) 头注释）：
;;;   GUIX_CONFIG_FACTS=<facts> guix time-machine -C channels.lock.scm \
;;;     -- system build -L "$PWD/modules" -e '(@ (guixcfg hosts laptop) %laptop-os)'

(define-module (guixcfg hosts laptop)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu home)                     ; home-environment（laptop home 组装）
               #:use-module (gnu services networking)      ; network-manager-service-type、wpa-supplicant-service-type
               #:use-module (gnu system shadow)            ; account-service-type（折叠 account 列表）
               #:use-module (guixcfg storage model)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:use-module (guixcfg boot layout)          ; %esp-mount-point
               #:use-module (guixcfg boot uki-bootloader)  ; uki-bootloader
               #:use-module (guixcfg system kernel-platform) ; %kernel、microcode-ephemeral-initrd（M1）
               #:use-module (guixcfg system desktop) ; desktop-services（M2 greetd/niri）
               #:use-module (guixcfg system graphics nvidia) ; nvidia-system-transformation（laptop 专属）
               #:use-module (guixcfg services ephemeral-root)
               #:use-module (guixcfg system common)
               #:use-module (guixcfg system file-systems)
               #:use-module (guixcfg system packages)
               #:use-module (guixcfg system ssh)       ; secure-ssh-service、ssh-host-key-service
               #:use-module (guixcfg system user-persistence)  ; selected user persistence
               #:use-module (guixcfg system readiness) ; boot readiness DAG
               #:use-module (guixcfg system accounts)  ; 纯 Scheme account 数据库投影
               #:use-module (guixcfg users user)       ; %primary-user（结构事实权威源）
               #:use-module (guixcfg home user)        ; guix-home（挂入 system）
               #:use-module (guixcfg security secrets)  ; runtime secrets 部署机制
               #:use-module (guixcfg apps registry)   ; %applications（secret composition root）
               #:use-module (guixcfg apps model)      ; applications-secrets、applications-persistence
               #:use-module (guixcfg apps selection)  ; application-configuration-selection
               #:use-module (guixcfg system application-persistence) ; application persistence generic executor
               #:use-module (guixcfg system mount-metadata) ; gvfs-mount-metadata-service
               #:use-module (guixcfg system mihomo service) ; mihomo-service（透明代理）
               #:use-module (guixcfg system dns ownership) ; system-dns-etc-service（DNS ownership）
               #:use-module (guixcfg system dns smartdns) ; smartdns-service（system resolver）
               #:use-module (guixcfg system machine-state-persistence) ; machine-state bind（mihomo providers）
               #:use-module (guixcfg system machine-identity) ; /etc/machine-id 持久化（先于 D-Bus activation）
               #:use-module (guixcfg system noctalia-greeter) ; noctalia-greeter machine-state bind + 系统集成
               
               #:use-module (gnu services guix)        ; guix-home-service-type
               #:use-module (virelith packages tpm2)   ; tpm2-tools-compat（enroll 工具依赖）
               #:use-module (srfi srfi-1)              ; remove
               #:export (%laptop-storage-policy
                         %laptop-application-configuration-selections
                         %laptop-guix-home
                         %laptop-services
                         %laptop-user-services
                         %laptop-os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %laptop-storage-policy storage:%laptop-storage-policy)

;; laptop 对 application 的 logical variant selection。本模块只表达
;; "选什么"，不表达"装什么文件/装到哪里"——改变 niri 'laptop
;; variant 背后的文件或目标路径不要求修改这里。
(define %laptop-application-configuration-selections
  (list (application-configuration-selection
         (application 'niri)
         (variant 'laptop))))

;; laptop 的 Guix Home 组合：默认 home + logical selections（由
;; generic resolver 解析为配置文件贡献）+ laptop-only host
;; capability：NVIDIA PRIME offload 的 host projection
;; （%prime-run-wrapper，Home profile 遮蔽 system profile 的
;; upstream nvidia-prime prime-run）。VM 不获得该 capability
;; （%guix-home 不含 wrapper；VM system 无 nvidia-service-type）。
(define %laptop-guix-home
  (let ((base (guix-home
               #:application-configuration-selections
               %laptop-application-configuration-selections)))
    (home-environment
     (inherit base)
     (packages (cons %prime-run-wrapper
                     (home-environment-packages base))))))

;; Primary user 来自 (guixcfg users user) 的 %primary-user（结构事实的
;; 唯一来源：username/uid/groups/shell/home）。密码 hash 不在此处——
;; user-account password 为 #f；hash 的 persistent verifier 由安装流程
;; 物化（/persist/system/accounts/<user>/password.hash），每 boot 由
;; account databases 投影内联进 ephemeral /etc/shadow
;;（docs/architecture/secrets.md（credential 三层模型））。
(define %laptop-users
  (list (primary-user-account)))

;; laptop 的 runtime secrets：mihomo（模块持有，所有设备共用）+
;; applications（registry 聚合）。无 VM 测试 sentinel（那是测试机专属）。
;; 按 readiness domain 分区后由两个 generic publisher 实例发布
;; （login-critical / ordinary 独立 transaction 与 capability；
;; ordinary 不 gate login）。
(define %laptop-secrets
  (append %mihomo-secrets
          (applications-secrets %applications)))

;; HOME persistence bind mounts（user data + app state；单一定义，
;; %laptop-services 的 gvfs-mount-metadata 服务与 file-systems 字段共用）。
(define %persistent-mount-file-systems
  (append (user-persistence-file-systems
           (user-profile-name %primary-user))
          (application-persistence-file-systems
           (applications-persistence %applications)
           (user-profile-name %primary-user))))

;; Mihomo 数据目录（providers cache + 选中节点/组状态）的 machine-state
;; bind（root-owned system state；backing/consumer 0700 由 mihomo
;; activation 强制——modules/guixcfg/system/mihomo/service.scm）。
(define %mihomo-machine-state-file-systems
  (machine-state-persistence-file-systems
   (list %mihomo-data-persistence-rule)))

;; Noctalia Greeter state dir（sync.toml / 同步 wallpaper / output
;; 状态）的 machine-state bind（greeter-owned system state；backing
;; 两侧 0750 + greeter:greeter 由 noctalia-greeter activation 强制——
;; modules/guixcfg/system/noctalia-greeter.scm）。
(define %noctalia-greeter-machine-state-file-systems
  (machine-state-persistence-file-systems
   (list %noctalia-greeter-persistence-rule)))

(define %laptop-services
  (append
   (list ;; 实机网络：NetworkManager 默认配置（shepherd-requirement
    ;; 默认 '(wireless-daemon)）+ 显式 wpa-supplicant 实例——pinned
    ;; Guix 的 network-manager-service-type 不会自动实例化
    ;; wpa-supplicant-service-type（其 shepherd provision 正是
    ;; 'wireless-daemon）。VM 无 WiFi，把 requirement 置空并省略
    ;; wpa-supplicant。DNS 语义同 VM（docs/architecture/dns.md）。
         (service network-manager-service-type)
         (service wpa-supplicant-service-type)
         ;; 系统 DNS ownership（Phase 2，docs/architecture/dns.md）：
         ;; /etc/resolv.conf 静态 127.0.0.1 + resolvconf 重定向 /run。
         (system-dns-etc-service)
         ;; SmartDNS：唯一 system resolver（loopback 监听 + 固定 upstream；
         ;; DHCP DNS metadata v1 只产出不消费）。
         (smartdns-service)
         ;; GVfs 桌面 metadata（x-gvfs-hide/x-gvfs-trash → utab）：
         ;; 在 file-systems 挂载后注入，让 GIO 对 HOME persistence
         ;; bind mounts 隐藏挂载并允许 mount-local trash。
         (gvfs-mount-metadata-service %persistent-mount-file-systems)
         ;; Mihomo 系统透明代理（Phase 1，docs/architecture/mihomo.md）：
         ;; Shepherd 独占生命周期；runtime config 由 materializer 合成
         ;; （secret URL 不进 store）；数据目录（providers cache +
         ;; 选中节点/组状态）经 machine-state bind 持久化。不做 DNS
         ;; （dns-hijack []）；SmartDNS upstream 经模板内 DIRECT 规则直连。
         (mihomo-service))
   ;; 无状态根的用户态服务：登录确认（last-good promote 挂在 greetd
   ;; PAM session open——成功图形登录后）与旧 generation 清理
   ;; （docs/architecture/storage.md，Root generation 一节）。
   (ephemeral-root-services
    (host-storage-policy-keep-root-generations %laptop-storage-policy))
   ;; 基础 session infrastructure（elogind：/run/user、XDG_RUNTIME_DIR、
   ;; PAM session——system/common 拥有）。
   %common-services
   ;; applications 的 system services（官方 service 实例；当前无 app
   ;; 声明——composition root 契约保留，同 persistence/secrets）。
   (applications-system-services %applications)
   ;; TTY login prompt 的强语义（与 VM 相同的策略，docs/architecture/
   ;; accounts-sessions.md）：login: 出现 = interactive-session-ready
   ;; 已过——mingetty 延迟到 barrier 之后；PAM gate 是 correctness
   ;; fallback。tty1 归 greetd（desktop-services）；其余 mingetty
   ;; （tty2-6）是普通 tty fallback（desktop 故障仍可登录；两者都
   ;; gated by interactive-session-ready）。tty1 的 mingetty 从
   ;; %base-services 移除（与 greetd 冲突）。
   (let* ((gated (modify-services %base-services
                                  (mingetty-service-type config =>
                                                         (mingetty-configuration
                                                          (inherit config)
                                                          (shepherd-requirement
                                                           (append (mingetty-configuration-shepherd-requirement config)
                                                                   '(interactive-session-ready)))))
                                  ;; guix-daemon 实例由 %common-services 显式
                                  ;; 声明（tmpdir=/var/tmp，本地构建空间政策，
                                  ;; 2026-08-25）——移除 %base-services 的默认
                                  ;; 实例，避免同类型双实例（fold 报错）。
                                  (delete guix-service-type)))
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
;; (b) 组装最终 %laptop-os。
(define %laptop-user-services
  (append
   (list (secure-ssh-service)
         (ssh-host-key-service)
         (user-persistence-service
          (user-profile-name %primary-user))
         ;; application persistence（generic executor；backing 创建 +
         ;; consumer parent ownership；bind mounts 见 file-systems）
         (application-persistence-service
          (applications-persistence %applications)
          (user-profile-name %primary-user))
         ;; machine-state persistence（root-owned system state；
         ;; consumers：mihomo 数据目录、noctalia-greeter state dir。
         ;; bind 见 %mihomo-machine-state-file-systems 与
         ;; %noctalia-greeter-machine-state-file-systems）
         (machine-state-persistence-service
          (list %mihomo-data-persistence-rule
                %noctalia-greeter-persistence-rule))
         ;; noctalia-greeter persistence backing 的 owner/mode
         ;; （bind 权限来源：backing 两侧 0750 greeter:greeter；
         ;; consumer 侧由 channel service 的 activation 负责——
         ;; modules/guixcfg/system/noctalia-greeter.scm 头部职责
         ;; 划分）。activation 先于 file-systems 挂载（pinned Guix
         ;; 行为），与 channel activation 无顺序冲突（两侧幂等、
         ;; 只修 owner/mode、不触碰内容）。
         (simple-service 'noctalia-greeter-backing-ownership
                         activation-service-type
                         (noctalia-greeter-backing-ownership-activation))
         ;; 声明式 runtime secrets（boot 时 root 解密；docs/
         ;; architecture/secrets.md）。composition root = host assembly：
         ;;   %laptop-secrets（mihomo + applications，无测试 sentinel）
         ;;   → 按 readiness domain 分区 → 两个 generic publisher
         ;;   实例（login-critical / ordinary 独立 transaction 与
         ;;   capability；ordinary 不 gate login）。
         (secrets-deploy-service
          (login-critical-secrets %laptop-secrets)
          (user-profile-name %primary-user))
         (secrets-ordinary-deploy-service
          (ordinary-secrets %laptop-secrets)
          (user-profile-name %primary-user))
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
                     ,%laptop-guix-home))))
   (append %laptop-services
           ;; boot readiness DAG（capability 链；login gate 的开启端在
           ;; interactive-session-ready）。guix-home-service-type 的
           ;; shepherd provision 是 guix-home-<user>（pinned
           ;; gnu/services/guix.scm）——从 %primary-user 派生，不
           ;; 硬编码用户名。
           (readiness-services
            (string->symbol
             (string-append "guix-home-"
                            (user-profile-name %primary-user))))
           ;; login gate：activation 关闭 + PAM gate（login/sshd account
           ;; 段 pam_nologin）
           (login-gate-services))))

;; 基础 OS：与最终 %laptop-os 完全相同，只是不含 account-databases 投影与
;; NVIDIA transformation。仅用于折叠 account 列表；真正启动用 %laptop-os。
(define %os-without-account-databases
  (operating-system
   (host-name "guix-laptop")
   (timezone %common-timezone)
   (locale %common-locale)
   
   ;; Limine + UKI + UEFI 直启（docs/architecture/boot.md）。
   ;; ESP 部署由 (guixcfg boot uki) 的部署脚本完成。
   (bootloader (bootloader-configuration
                (bootloader uki-bootloader)
                (targets (list %esp-mount-point))))
   
   (mapped-devices (cryptroot-mapped-devices))
   
   ;; Kernel platform（M1）：Nonguix standard Linux + linux-firmware +
   ;; Intel microcode。kernel/firmware/microcode 的唯一权威定义在
   ;; (guixcfg system kernel-platform)（docs/architecture/boot.md）。
   ;; NVIDIA 不改变此字段（adapter 只 consume，不另选 kernel）。
   (kernel %kernel)
   (firmware (list %kernel-firmware))
   
   ;; 无状态根（docs/architecture/storage.md）：initrd 启动时按
   ;; @persist-system/root-generations/state.scm 选择/创建 @root-N，
   ;; 挂到 /selected-root 后由 boot-system bind 成系统根。
   ;; microcode-ephemeral-initrd = microcode cpio 拼接 custom initrd
   ;; （composition，custom initrd 仍是 authoritative payload）。
   (initrd microcode-ephemeral-initrd)
   (file-systems (append (system-file-systems %ephemeral-root-file-system)
                         ;; selected user persistence（bind mounts，登录前就位）
                         %persistent-mount-file-systems
                         ;; machine-state binds（root-owned：mihomo providers；
                         ;; greeter-owned：noctalia-greeter state）
                         %mihomo-machine-state-file-systems
                         %noctalia-greeter-machine-state-file-systems
                         %base-file-systems))
   
   (swap-devices %swap-spaces)
   
   (users %laptop-users)
   ;; tpm2-tools-compat 显式加入 system profile：tpm2-enroll 工具
   ;; （guix repl tools/tpm2-enroll.scm）依赖
   ;; /run/current-system/profile/bin/tpm2_{pcrread,createprimary,...}，
   ;; 必须来自锁定 Virelith 的 compat 包（docs/architecture/boot.md（TPM2））。
   (packages (append (list tpm2-tools-compat) %system-packages))
   (services %laptop-user-services)))

;; 完整 account 列表 = account-service-type 的 folded value（root +
;; 声明的 users/groups + 全部服务贡献的 account，如 guixbuilder01-10、
;; sshd、messagebus、polkitd）。account-databases 投影自身不扩展
;; account-service-type，因此含不含它对折叠结果无影响——先在一个
;; 不含它的 probe OS 上折叠，再组装最终 %laptop-os（避免自引用）。
;; NVIDIA 不扩展 account-service-type（pinned nongnu/services/
;; nvidia.scm），因此 transformation 与折叠互不影响。
(define %laptop-accounts+groups
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
;; machine-identity 紧随其后（列表倒数第二）：user activation 段最
;; 先执行的顺序中排在第二，严格先于 %base-services 系 D-Bus
;; activation 的 dbus-uuidgen --ensure=/etc/machine-id（D-Bus service
;; 由 instantiate-missing-services 插到列表头部 = user activation 段
;; 最后执行）——/etc/machine-id 在 D-Bus 之前就位
;; （docs/architecture/persistence.md（Machine identity）；
;; tests/test-machine-identity.scm 断言该顺序）。
;; 最后套 NVIDIA adapter：只改 kernel-arguments/packages/services，
;; kernel/initrd/firmware 原样保留（%kernel 仍是被选内核）。
;; 命名为 %laptop-os 而非 %laptop-os：避免与 (guixcfg hosts vm) 的 %laptop-os 在
;; 同时 import 两个 host 模块时产生跨模块绑定歧义（测试套件实测）。
(define %laptop-os
  (nvidia-system-transformation
   (operating-system
    (inherit %os-without-account-databases)
    (services (append (operating-system-user-services
                       %os-without-account-databases)
                      (list (machine-identity-service)
                            (account-databases-service
                             %laptop-accounts+groups)))))))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts laptop)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/laptop.scm /mnt
%laptop-os
