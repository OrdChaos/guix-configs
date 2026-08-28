;;; VM 最终 <operating-system> 组装点（docs/README.md）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %os)'

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; network-manager-service-type
               #:use-module (gnu system shadow)            ; account-service-type（折叠 account 列表）
               #:use-module (guixcfg storage model)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:use-module (guixcfg boot layout)          ; %esp-mount-point
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
               #:use-module (guixcfg utils repository-source) ; repository-file（VM 测试 sentinel 密文）
               #:use-module (guixcfg apps registry)   ; %applications（secret composition root）
               #:use-module (guixcfg apps model)      ; applications-secrets、applications-persistence
               #:use-module (guixcfg system application-persistence) ; application persistence generic executor
               #:use-module (guixcfg system mount-metadata) ; gvfs-mount-metadata-service
               #:use-module (guixcfg system mihomo service) ; mihomo-service（透明代理）
               #:use-module (guixcfg system dns ownership) ; system-dns-etc-service（DNS ownership）
               #:use-module (guixcfg system dns smartdns) ; smartdns-service（system resolver）
               #:use-module (guixcfg system machine-state-persistence) ; machine-state bind（mihomo providers）
               #:use-module (guixcfg system noctalia-greeter) ; noctalia-greeter machine-state bind + 系统集成

               #:use-module (gnu services guix)        ; guix-home-service-type
               #:use-module (virelith packages tpm2)   ; tpm2-tools-compat（enroll 工具依赖）
               #:use-module (srfi srfi-1)              ; remove
               #:export (%vm-storage-policy %vm-services %vm-test-secrets %os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %vm-storage-policy storage:%vm-storage-policy)

;; Primary user 来自 (guixcfg users user) 的 %primary-user（结构事实的
;; 唯一来源：username/uid/groups/shell/home）。密码 hash 不在此处——
;; user-account password 为 #f；hash 的 persistent verifier 由安装流程
;; 物化（/persist/system/accounts/<user>/password.hash），每 boot 由
;; account databases 投影内联进 ephemeral /etc/shadow
;;（docs/architecture/secrets.md（credential 三层模型））。
(define %vm-users
  (list (primary-user-account)))

;; VM 测试机的 secrets 机制 sentinel（不是 host-owned secret 层——
;; 只是这台测试机要部署的测试密文；密文归 tests/fixtures/secrets/，
;; 经 repository-file（仓库根相对）解析。laptop 等真实 host 不需要。
(define %vm-test-secrets
  (list (secret-decl
         (name 'test-system)
         (scope 'system)
         (domain 'login-critical)
         (source (repository-file "tests/fixtures/secrets/test-system.age"))
         (target-name "test-system")
         (owner-user "root")
         (mode #o400))
        (secret-decl
         (name 'test-user)
         (scope 'user)
         (domain 'login-critical)
         (source (repository-file "tests/fixtures/secrets/test-user.age"))
         (target-name "test-user")
         (owner-user (user-profile-name %primary-user))
         (mode #o600))))

;; HOME persistence bind mounts（user data + app state；单一定义，
;; %vm-services 的 gvfs-mount-metadata 服务与 file-systems 字段共用）。
(define %persistent-mount-file-systems
  (append (user-persistence-file-systems
           (user-profile-name %primary-user))
          (application-persistence-file-systems
           (applications-persistence %applications)
           (user-profile-name %primary-user))))

;; Mihomo 数据目录（providers cache + 选中节点/组状态）的 machine-state
;; bind（root-owned system state；
;; 与 HOME persistence 不同层，单独成表）。backing/consumer 0700 由
;; mihomo activation 强制（modules/guixcfg/system/mihomo/service.scm）。
(define %mihomo-machine-state-file-systems
  (machine-state-persistence-file-systems
   (list %mihomo-data-persistence-rule)))

;; Noctalia Greeter state dir（sync.toml / 同步 wallpaper / output
;; 状态）的 machine-state bind（greeter-owned system state；
;; backing/consumer 0750 + greeter:greeter 由 noctalia-greeter
;; activation 强制——modules/guixcfg/system/noctalia-greeter.scm）。
(define %noctalia-greeter-machine-state-file-systems
  (machine-state-persistence-file-systems
   (list %noctalia-greeter-persistence-rule)))

(define %vm-services
  (append
   (list ;; QEMU user-mode 网络（SLIRP：DHCP 10.0.2.15 / DNS 10.0.2.3）：
    ;; NetworkManager——网络配置唯一 owner；DNS 语义见
    ;; docs/architecture/dns.md：NM 仍以 rc-manager=resolvconf
    ;; （编译期默认）调用 resolvconf -a，但 libc subscriber 被
    ;; /etc/resolvconf.conf 重定向到 /run（DHCP DNS = upstream
    ;; metadata），/etc/resolv.conf 归 (guixcfg system dns ownership) 静态
    ;; 声明（nameserver 127.0.0.1）。因此不再需要
    ;; resolvconf-bootstrap（签名接管问题随静态 ownership 消失）。
    (service network-manager-service-type
             ;; VM 无 WiFi：保留默认 '(wireless-daemon) requirement
             ;; 会因缺服务 fail-fast（pinned network-manager-configuration
             ;; 默认 '(wireless-daemon)）——显式置空；基础 requirement
             ;; user-processes/dbus-system/loopback 由 pinned
             ;; network-manager-shepherd-service 自带，不受本字段影响。
             (network-manager-configuration
              (shepherd-requirement '())))
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
    ;; 选中节点/组状态）经 machine-state bind 持久化。不做 DNS（dns-hijack []）；SmartDNS upstream 经
    ;; 模板内 DIRECT 规则直连（不绕经节点）。
    (mihomo-service))
   ;; 无状态根的用户态服务：登录确认（last-good promote 挂在 greetd
   ;; PAM session open——成功图形登录后）与旧 generation 清理
   ;; （docs/architecture/storage.md，Root generation 一节）。
   (ephemeral-root-services
    (host-storage-policy-keep-root-generations %vm-storage-policy))
   ;; 基础 session infrastructure（elogind：/run/user、XDG_RUNTIME_DIR、
   ;; PAM session——system/common 拥有）。
   %common-services
   ;; applications 的 system services（官方 service 实例；当前无 app
   ;; 声明——composition root 契约保留，同 persistence/secrets）。
   (applications-system-services %applications)
   ;; TTY login prompt 的强语义（docs/architecture/accounts-sessions.md）：
   ;; login: 出现 =
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
;; (b) 组装最终 %os。
(define %vm-user-services
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
         ;;   %vm-test-secrets（本测试机的机制 sentinel） +
         ;;   %mihomo-secrets（mihomo 模块持有，所有设备共用） +
         ;;   applications-secrets（registry 聚合）→ 按 readiness
         ;;   domain 分区 → 两个 generic publisher 实例（login-critical /
         ;;   ordinary 独立 transaction 与 capability；ordinary 不 gate
         ;;   login）。
         (secrets-deploy-service
          (login-critical-secrets
           (append %vm-test-secrets
                   %mihomo-secrets
                   (applications-secrets %applications)))
          (user-profile-name %primary-user))
         (secrets-ordinary-deploy-service
          (ordinary-secrets
           (append %vm-test-secrets
                   %mihomo-secrets
                   (applications-secrets %applications)))
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
                     ,%guix-home))))
   (append %vm-services
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
                (targets (list %esp-mount-point))))
   
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
                         ;; selected user persistence（bind mounts，登录前就位）
                         %persistent-mount-file-systems
                         ;; machine-state binds（root-owned：mihomo providers；
                         ;; greeter-owned：noctalia-greeter state）
                         %mihomo-machine-state-file-systems
                         %noctalia-greeter-machine-state-file-systems
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
