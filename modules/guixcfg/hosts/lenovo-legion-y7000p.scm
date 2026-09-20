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
;;; 与 VM 的共享组装算法在 (guixcfg hosts common)。本模块只保留
;;; Laptop 的 policy 差异：
;;;   1. 网络：NetworkManager 默认 shepherd-requirement
;;;      '(wireless-daemon) + 显式 wpa-supplicant 实例（pinned Guix
;;;      不会自动实例化 wpa-supplicant-service-type）；
;;;   2. secrets：%lenovo-legion-y7000p-secrets = mihomo + applications；
;;;   3. home：%lenovo-legion-y7000p-guix-home（niri 'laptop variant selection +
;;;      laptop-only host capability %prime-run-wrapper + Flatpak PRIME
;;;      environment adapter）；
;;;   4. NVIDIA：最终 OS 套 nvidia-system-transformation（open kernel
;;;      module + dynamic boost；kernel 不被替换）。
;;;   5. Flatpak：selection 是全局用户软件 policy（所有设备一致）；
;;;      本 host 只叠加 NVIDIA PRIME managed override adapter。
;;;
;;; 构建（需要 machine facts，见 (guixcfg system file-systems) 头注释）：
;;;   GUIX_CONFIG_FACTS=<facts> GUILE_LOAD_PATH="$PWD/modules" \
;;;     GUILE_LOAD_COMPILED_PATH="$PWD/modules" \
;;;     guix time-machine -C channels.lock.scm -- system build \
;;;     -e '(@ (guixcfg hosts lenovo-legion-y7000p) %lenovo-legion-y7000p-os)'

(define-module (guixcfg hosts lenovo-legion-y7000p)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu home)                     ; home-environment（laptop home 组装）
               #:use-module (gnu services networking)      ; network-manager-service-type、wpa-supplicant-service-type
                #:use-module (guixcfg storage model)          ; host-storage-policy-keep-root-generations
                #:use-module ((guixcfg storage policies) #:prefix storage:)
                #:use-module (guixcfg hosts common)         ; 共享 host composition algorithm
                #:use-module (guixcfg inventory hosts)      ; Host ID → hostname 单一映射
                #:use-module (guixcfg system graphics nvidia) ; nvidia-system-transformation（laptop 专属）
                #:use-module (guixcfg system gaming)        ; gaming host infrastructure（controller udev + 游戏库目录）
               #:use-module (guixcfg users user)           ; %primary-user（结构事实权威源）
               #:use-module (guixcfg home user)            ; guix-home（挂入 system）
               #:use-module (guixcfg security secrets)     ; secrets 部署机制
                #:use-module (guixcfg apps registry)   ; %applications（secret composition root）
                #:use-module (guixcfg apps model)      ; applications-secrets
                #:use-module (guixcfg apps selection)  ; application-configuration-selection
                #:use-module (guixcfg system machine-state-persistence) ; machine-state binds
               #:use-module (guixcfg system network-manager-persistence) ; saved connection profiles
               #:use-module (guixcfg system noctalia-greeter) ; noctalia-greeter machine-state bind
               #:use-module (guixcfg system mihomo service) ; %mihomo-secrets、%mihomo-data-persistence-rule
                #:export (%lenovo-legion-y7000p-storage-policy
                          %lenovo-legion-y7000p-application-configuration-selections
                          %lenovo-legion-y7000p-guix-home
                          %lenovo-legion-y7000p-services
                          %lenovo-legion-y7000p-user-services
                          %lenovo-legion-y7000p-os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %lenovo-legion-y7000p-storage-policy
  storage:%lenovo-legion-y7000p-storage-policy)

;; laptop 对 application 的 logical variant selection。本模块只表达
;; "选什么"，不表达"装什么文件/装到哪里"——改变 niri 'laptop
;; variant 背后的文件或目标路径不要求修改这里。
(define %lenovo-legion-y7000p-application-configuration-selections
  (list (application-configuration-selection
         (application 'niri)
         (variant 'laptop))))

;; laptop 的 Guix Home 组合：默认 home + logical selections（由
;; generic resolver 解析为配置文件贡献）+ laptop-only host
;; capability：NVIDIA PRIME offload 的 host projection
;; （%prime-run-wrapper，Home profile 遮蔽 system profile 的
;; upstream nvidia-prime prime-run）与 Flatpak PRIME environment
;; adapter（%flatpak-prime-environment-overrides——只作用于
;; managed override，VM 传空 overlay 时不产生 __NV_* 变量）。
(define %lenovo-legion-y7000p-guix-home
  (let ((base (guix-home
               #:application-configuration-selections
               %lenovo-legion-y7000p-application-configuration-selections
               #:flatpak-environment-overrides
               %flatpak-prime-environment-overrides)))
    (home-environment
     (inherit base)
     (packages (cons %prime-run-wrapper
                     (home-environment-packages base))))))

;; laptop 的 runtime secrets：mihomo（模块持有，所有设备共用）+
;; applications（registry 聚合）。无 VM 测试 sentinel（那是测试机专属）。
(define %lenovo-legion-y7000p-secrets
  (append %mihomo-secrets
          (applications-secrets %applications)))

;; HOME persistence bind mounts（user data + app state；单一定义，
;; %lenovo-legion-y7000p-services 的 gvfs-mount-metadata 服务与 file-systems 字段
;; 共用）。Flatpak 部分使用 common 的共享事实（全局 selection 投影）。
(define %persistent-mount-file-systems
  (host-persistent-mount-file-systems))

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

;; GUI-created NetworkManager keyfile profiles only.  Derived/volatile state
;; under /var/lib/NetworkManager remains on the ephemeral root.
(define %network-manager-machine-state-file-systems
  (machine-state-persistence-file-systems
   (list %network-manager-connections-persistence-rule)))

(define %lenovo-legion-y7000p-services
  (append
   (make-host-services
    ;; 实机网络：NetworkManager 默认配置 + 显式 wpa-supplicant。
    ;; DNS 语义同 VM（docs/architecture/dns.md）。
    #:network-services
    (list (service network-manager-service-type)
          (service wpa-supplicant-service-type))
    #:keep-root-generations
    (host-storage-policy-keep-root-generations
     %lenovo-legion-y7000p-storage-policy)
    #:persistent-mount-file-systems %persistent-mount-file-systems
    ;; 无 host-only system services（gaming 基础设施已全局共享；
    ;; NVIDIA/PRIME capability 在 final transformation 与 Guix Home）。
    #:additional-system-services '())
   ;; Activation precedes Shepherd's mounts and NetworkManager startup.
   (list (network-manager-connections-persistence-service))))

;; 完整 user services（不含 account-databases 投影本身）。
(define %lenovo-legion-y7000p-user-services
  (make-host-user-services
   #:system-services %lenovo-legion-y7000p-services
   #:application-persistence-rules
   (host-application-persistence-rules)
   #:additional-machine-state-persistence-rules
   (list %network-manager-connections-persistence-rule)
   #:secrets %lenovo-legion-y7000p-secrets
   #:home-environment %lenovo-legion-y7000p-guix-home))

;; 基础 OS：与最终 %lenovo-legion-y7000p-os 完全相同，只是不含 account-databases
;; 投影与 NVIDIA transformation。仅用于折叠 account 列表。
(define %os-without-account-databases
  (make-base-host-operating-system
   #:host-name (host-name-for-id "lenovo-legion-y7000p")
   #:persistent-mount-file-systems %persistent-mount-file-systems
   #:mihomo-machine-state-file-systems %mihomo-machine-state-file-systems
   #:noctalia-greeter-machine-state-file-systems
   %noctalia-greeter-machine-state-file-systems
   #:additional-machine-state-file-systems
   %network-manager-machine-state-file-systems
   #:user-services %lenovo-legion-y7000p-user-services))

;; 最终 OS：account fold + machine-identity + account-databases 投影，
;; 最后套 NVIDIA adapter（只改 kernel-arguments/packages/services，
;; kernel/initrd/firmware 原样保留——%kernel 仍是被选内核）。
(define %lenovo-legion-y7000p-os
  (make-host-operating-system
   %os-without-account-databases
   #:final-transformation nvidia-system-transformation))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块
;; (guixcfg hosts lenovo-legion-y7000p)，又是入口：
;;   GUILE_LOAD_PATH="$PWD/modules" guix system init modules/guixcfg/hosts/lenovo-legion-y7000p.scm /mnt
%lenovo-legion-y7000p-os
