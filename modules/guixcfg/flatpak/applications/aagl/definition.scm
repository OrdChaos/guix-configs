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
;;; override policy：(managed-overrides <flatpak-override>)——文件本身
;;; 硬件中性。Guix 会话导出的 GIT_EXEC_PATH 指向宿主 profile，Flatpak
;;; sandbox 无法访问；AAGL 又调用包内 git 同步组件索引，因此固定为
;;; Flathub 包内 helper 目录 /app/libexec/git-core。游戏内容经
;;; /persist/data-nobackup/aagl 直接访问（路径 authority 在
;;; (guixcfg system gaming)）。
;;; 硬件差异（如 NVIDIA PRIME offload）由 hardware adapter 在
;;; Lenovo Guix Home 经 (flatpak-applications-with-environments)
;;; 追加 environment（变量语义归 (guixcfg system graphics nvidia)
;;; 单一 authority）——global selection 与 definition 保持
;;; hardware-neutral。Gamescope 支持来自上游 wrapper
;;; （/usr/lib/extensions/vulkan/gamescope/bin 的 PATH；gamescope
;;; extension 见 extensions/gamescope/definition.scm，全局 selection
;;; 安装）。
;;;
;;; persistence：默认 ~/.var/app/moe.launcher.an-anime-game-launcher
;;; 由 ID 推导（service 投影，无需在此声明）。AAGL 的 config.json 位于
;;; data/anime-game-launcher/，混合偏好、机器路径与下载组件状态，并由
;;; launcher 整文件重写；因此它属于 app-owned mutable state，不作为
;;; Home file 或 seed 从仓库派生（详见 flatpak.md（AAGL config））。

(define-module (guixcfg flatpak applications aagl definition)
                #:use-module (guixcfg flatpak model)
                #:use-module (guixcfg system gaming)
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
            (filesystems (list %aagl-games-library-path))
            (environment
             '("GIT_EXEC_PATH=/app/libexec/git-core")))))))
