;;; An Anime Game Launcher application definition（Flatpak；
;;; docs/architecture/flatpak.md（application model））。
;;;
;;; 自包含 definition：identity / Flatpak ref metadata / update
;;; policy / override policy / persistence intent 全部属于本文件；
;;; registry 只聚合（(guixcfg flatpak registry)），selection 只
;;; 选择 logical name，service/reconcile 从 definition 投影。
;;;
;;; 选型理由：AAGL（Rust/GTK 启动器，Guix 无对应包）上游以
;;; Flatpak 为官方 Linux 分发形态（flathub.org/apps/
;;; moe.launcher.an-anime-game-launcher）。app-id/branch 以上游
;;; Flathub 仓库核实。
;;;
;;; update policy：'track-branch（默认策略）。
;;;
;;; override policy：(managed-overrides ...)——追加 NVIDIA PRIME
;;; offload 环境（投影自 %prime-offload-environment-strings，变量
;;; 语义归 (guixcfg system graphics nvidia)）。本 app 因此只适合
;;; 有 nvidia 的 host：selection 是 host 决策（lenovo 选入，VM
;;; 缺省不选——VM 无 nvidia GLX vendor，__GLX_VENDOR_LIBRARY_NAME
;;; 会导致 GLX 初始化失败）。Gamescope 支持来自上游 wrapper
;;; （/usr/lib/extensions/vulkan/gamescope/bin 的 PATH；gamescope
;;; extension 见 extensions/gamescope.scm，按需安装）。
;;;
;;; persistence：默认 ~/.var/app/moe.launcher.an-anime-game-launcher
;;; 由 ID 推导（service 投影，无需在此声明）。
;;;
;;; Gamescope：上游 wrapper 支持
;;; org.freedesktop.Platform.VulkanLayer.gamescope（经
;;; /usr/lib/extensions/vulkan/gamescope/bin 的 PATH）；
;;; extension 由 host 的 extension selection 管理
;;; （extensions/gamescope.scm，docs/architecture/flatpak.md）。

(define-module (guixcfg flatpak applications aagl)
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg system graphics nvidia) ; %prime-offload-environment-strings
               #:export (%flatpak-aagl))

(define %flatpak-aagl
  (flatpak-application
   (name 'aagl)
   (id "moe.launcher.an-anime-game-launcher")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy
    (list 'managed-overrides
          (flatpak-override
           (environment %prime-offload-environment-strings))))))
