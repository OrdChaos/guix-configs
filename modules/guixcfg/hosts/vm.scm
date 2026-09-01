;;; VM 最终 <operating-system> 组装点（docs/README.md）。
;;;
;;; 构建：guix time-machine -C channels.lock.scm -- system build \
;;;         -L modules -e '(@ (guixcfg hosts vm) %vm-os)'
;;;
;;; 与 Laptop 的共享组装算法在 (guixcfg hosts common)（services /
;;; user-services / 基础 OS / account fold + 最终 OS）。本模块只
;;; 保留 VM 的 policy 差异：
;;;   1. 网络：NetworkManager 空 shepherd-requirement（无 WiFi——
;;;      pinned 默认 requirement '(wireless-daemon) 会因缺服务
;;;      fail-fast），无 wpa-supplicant；
;;;   2. persistence：application rules 含 Flatpak 平台
;;;      （installation + 每 selected app）；
;;;   3. secrets：含 %vm-test-secrets（本测试机的机制 sentinel）；
;;;   4. home：默认 %guix-home（无 host variant selection）；
;;;   5. 无 NVIDIA/PRIME capability（nvidia-service-type 零贡献，
;;;      tests/test-nvidia.scm N6 断言）。

(define-module (guixcfg hosts vm)
               #:use-module (gnu)                          ; operating-system、user-account、service 等
               #:use-module (gnu services networking)      ; network-manager-service-type
               #:use-module (guixcfg storage model)          ; host-storage-policy-keep-root-generations
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg hosts common)         ; 共享 host composition algorithm
               #:use-module (guixcfg users user)           ; %primary-user（结构事实权威源）
               #:use-module (guixcfg home user)            ; %guix-home（挂入 system）
               #:use-module (guixcfg security secrets)     ; secret-decl
               #:use-module (guixcfg utils repository-source) ; repository-file（VM 测试 sentinel 密文）
               #:use-module (guixcfg apps registry)   ; %applications（secret composition root）
               #:use-module (guixcfg apps model)      ; applications-secrets、applications-persistence
               #:use-module (guixcfg system user-persistence)  ; selected user persistence
               #:use-module (guixcfg system application-persistence) ; application persistence generic executor
               #:use-module (guixcfg system machine-state-persistence) ; machine-state bind（mihomo providers）
               #:use-module (guixcfg system noctalia-greeter) ; noctalia-greeter machine-state bind
               #:use-module (guixcfg system mihomo service) ; %mihomo-secrets、%mihomo-data-persistence-rule
               #:use-module (guixcfg flatpak service) ; flatpak-persistence-rules（installation + 每 selected app）
               #:export (%vm-storage-policy %vm-services %vm-test-secrets %vm-os))

;; 保留 host 模块原有导出名；实际 policy 放在纯存储模块中，避免早期
;; disk-install 为取 policy 而加载完整 OS/UKI/channel 依赖。
(define %vm-storage-policy storage:%vm-storage-policy)

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
;; app state 含 Flatpak 平台规则（installation + 每 selected app——
;; 经 application-persistence generic engine，零专属 mount 代码）。
(define %persistent-mount-file-systems
  (append (user-persistence-file-systems
           (user-profile-name %primary-user))
          (application-persistence-file-systems
           (append (applications-persistence %applications)
                   (flatpak-persistence-rules))
           (user-profile-name %primary-user))))

;; Mihomo 数据目录（providers cache + 选中节点/组状态）的 machine-state
;; bind（root-owned system state；backing/consumer 0700 由 mihomo
;; activation 强制——modules/guixcfg/system/mihomo/service.scm）。
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
  (make-host-services
   ;; QEMU user-mode 网络（SLIRP：DHCP 10.0.2.15 / DNS 10.0.2.3）。
   ;; DNS 语义见 docs/architecture/dns.md（/etc/resolv.conf 归
   ;; (guixcfg system dns ownership) 静态声明）。
   #:network-services
   (list (service network-manager-service-type
                  (network-manager-configuration
                   (shepherd-requirement '()))))
   #:keep-root-generations
   (host-storage-policy-keep-root-generations %vm-storage-policy)
   #:persistent-mount-file-systems %persistent-mount-file-systems))

;; 完整 user services（不含 account-databases 投影本身）。
(define %vm-user-services
  (make-host-user-services
   #:system-services %vm-services
   #:application-persistence-rules
   (append (applications-persistence %applications)
           (flatpak-persistence-rules))
   #:secrets (append %vm-test-secrets
                     %mihomo-secrets
                     (applications-secrets %applications))
   #:home-environment %guix-home))

;; 基础 OS：与最终 %vm-os 完全相同，只是不含 account-databases 投影。
;; 仅用于折叠 account 列表；真正启动用 %vm-os。
(define %os-without-account-databases
  (make-base-host-operating-system
   #:host-name "guix-vm"
   #:persistent-mount-file-systems %persistent-mount-file-systems
   #:mihomo-machine-state-file-systems %mihomo-machine-state-file-systems
   #:noctalia-greeter-machine-state-file-systems
   %noctalia-greeter-machine-state-file-systems
   #:user-services %vm-user-services))

;; 最终 OS：account fold + machine-identity + account-databases 投影
;; （共享组装算法，无 final transformation——VM 无 NVIDIA）。
(define %vm-os
  (make-host-operating-system %os-without-account-databases))

;; 末尾裸表达式：让本文件同时是 guix system 的入口文件——
;; guix system init/reconfigure 加载文件时取最后一个顶层表达式的值
;; （daviwil 模式）。因此本文件既是模块 (guixcfg hosts vm)，又是入口：
;;   guix system init -L modules modules/guixcfg/hosts/vm.scm /mnt
%vm-os
