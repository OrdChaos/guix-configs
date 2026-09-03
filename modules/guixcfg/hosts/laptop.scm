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
;;;   2. secrets：%laptop-secrets = mihomo + applications（无测试
;;;      sentinel）；
;;;   3. home：%laptop-guix-home（niri 'laptop variant selection +
;;;      laptop-only host capability %prime-run-wrapper）；
;;;   4. NVIDIA：最终 OS 套 nvidia-system-transformation（open kernel
;;;      module + dynamic boost；kernel 不被替换）。
;;; （Flatpak 与 application persistence 规则自 2026-09 起在 common
;;; 共享——不再是 host 差异。）
;;;
;;; 构建（需要 machine facts，见 (guixcfg system file-systems) 头注释）：
;;;   GUIX_CONFIG_FACTS=<facts> guix time-machine -C channels.lock.scm \
;;;     -- system build -L "$PWD/modules" -e '(@ (guixcfg hosts laptop) %laptop-os)'

(define-module (guixcfg hosts laptop)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu home)                     ; home-environment（laptop home 组装）
               #:use-module (gnu services networking)      ; network-manager-service-type、wpa-supplicant-service-type
               #:use-module (guixcfg storage model)          ; host-storage-policy-keep-root-generations
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg hosts common)         ; 共享 host composition algorithm
               #:use-module (guixcfg system graphics nvidia) ; nvidia-system-transformation（laptop 专属）
               #:use-module (guixcfg users user)           ; %primary-user（结构事实权威源）
               #:use-module (guixcfg home user)            ; guix-home（挂入 system）
               #:use-module (guixcfg security secrets)     ; secrets 部署机制
               #:use-module (guixcfg apps registry)   ; %applications（secret composition root）
               #:use-module (guixcfg apps model)      ; applications-secrets
               #:use-module (guixcfg apps selection)  ; application-configuration-selection
               #:use-module (guixcfg system machine-state-persistence) ; machine-state bind（mihomo providers）
               #:use-module (guixcfg system noctalia-greeter) ; noctalia-greeter machine-state bind
               #:use-module (guixcfg system mihomo service) ; %mihomo-secrets、%mihomo-data-persistence-rule
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

;; laptop 的 runtime secrets：mihomo（模块持有，所有设备共用）+
;; applications（registry 聚合）。无 VM 测试 sentinel（那是测试机专属）。
(define %laptop-secrets
  (append %mihomo-secrets
          (applications-secrets %applications)))

;; HOME persistence bind mounts（user data + app state；单一定义，
;; %laptop-services 的 gvfs-mount-metadata 服务与 file-systems 字段
;; 共用）。列表本身是 common 的共享事实（含 Flatpak 平台规则——
;; 所有 host 都用，2026-09 起不再是 host 差异）。
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

(define %laptop-services
  (make-host-services
   ;; 实机网络：NetworkManager 默认配置 + 显式 wpa-supplicant。
   ;; DNS 语义同 VM（docs/architecture/dns.md）。
   #:network-services
   (list (service network-manager-service-type)
         (service wpa-supplicant-service-type))
   #:keep-root-generations
   (host-storage-policy-keep-root-generations %laptop-storage-policy)
   #:persistent-mount-file-systems %persistent-mount-file-systems))

;; 完整 user services（不含 account-databases 投影本身）。
(define %laptop-user-services
  (make-host-user-services
   #:system-services %laptop-services
   #:secrets %laptop-secrets
   #:home-environment %laptop-guix-home))

;; 基础 OS：与最终 %laptop-os 完全相同，只是不含 account-databases
;; 投影与 NVIDIA transformation。仅用于折叠 account 列表。
(define %os-without-account-databases
  (make-base-host-operating-system
   #:host-name "guix-laptop"
   #:persistent-mount-file-systems %persistent-mount-file-systems
   #:mihomo-machine-state-file-systems %mihomo-machine-state-file-systems
   #:noctalia-greeter-machine-state-file-systems
   %noctalia-greeter-machine-state-file-systems
   #:user-services %laptop-user-services))

;; 最终 OS：account fold + machine-identity + account-databases 投影，
;; 最后套 NVIDIA adapter（只改 kernel-arguments/packages/services，
;; kernel/initrd/firmware 原样保留——%kernel 仍是被选内核）。
(define %laptop-os
  (make-host-operating-system
   %os-without-account-databases
   #:final-transformation nvidia-system-transformation))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts laptop)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/laptop.scm /mnt
%laptop-os
