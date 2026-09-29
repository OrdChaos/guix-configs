;;; anime-game-launcher application unit: An Anime Game Launcher
;;; (Genshin Impact launcher) from the Virelith channel.
;;;
;;; 来源： (virelith packages anime-launchers) 的
;;; anime-game-launcher-bin——上游 an-anime-team 官方 release 二进制
;;; （GPL-3.0，nonguix binary-build-system 重写 interpreter/RUNPATH，
;;; 详见包内注释）。原生包取代了此前的 Flatpak 分发
;;; （旧定义 modules/guixcfg/flatpak/applications/aagl/，已删除）。
;;;
;;; Persistence boundary (AAGL 3.19.8 / anime-launcher-sdk 1.36.11
;;; source audit，src/main.rs lazy_static):
;;;   ~/.local/share/anime-game-launcher   launcher state。整个目录是
;;;     单一 app-owned mutable unit：config.json（混合偏好、机器
;;;      路径与下载组件状态，preferences/main window 关闭时整文件
;;;      重写）、.first-run/.keep-background marker、background 主题
;;;      文件、runners/ 与 dxvks/（已下载 Wine/DXVK）、prefix/（Wine
;;;      prefix）、components/（组件索引与缓存）、fps-unlocker/ 等。
;;;      config 由 launcher 自己初始化与重写，故不作为 Home file 或
;;;      seed 从仓库派生（应用自有状态，与旧 Flatpak 结论一致）。
;;;   ~/.cache/anime-game-launcher         processed background/video
;;;       cache，可重建；不持久化。
;;;
;;; 游戏本体不进 app persistence：用户在 first-run 的 game
;;; installation folder 选择 /persist/data-nobackup/aagl（bulk、
;;; reacquirable storage；路径 authority 是 (guixcfg system gaming)，
;;; 目录由其 activation 建好并归还 USER），因此备份单元只含
;;; launcher 状态而不含数十 GB 游戏内容。

(define-module (guixcfg apps anime-game-launcher definition)
                #:use-module (virelith packages anime-launchers)
                #:use-module (guixcfg apps model)
                #:use-module (guixcfg system application-persistence)
                #:export (%anime-game-launcher))

(define %anime-game-launcher
  (application
   (name 'anime-game-launcher)
   (home-packages (list anime-game-launcher-bin))
   (persistence
    (list (application-persistence-rule
           (name 'data)
           (backing "anime-game-launcher/data")
           (consumer ".local/share/anime-game-launcher")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
