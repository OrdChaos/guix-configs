;;; Steam application definition（Flatpak；docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 选型（2026-09 调研结论）：Guix/Nonguix 均无 gamescope；公开
;;; Guix 配置无一使用 Flatpak Steam，但 Flatpak 路线的
;;; gamescope 是上游官方支持路径（steam wrapper 自动把
;;; VulkanLayer extension bin 加入 PATH），且与 AAGL 共用同一
;;; gamescope extension。NVIDIA GL/GL32 extension 按内核模块
;;; 版本自动匹配（flatpak --gl-drivers），驱动升级仪式见
;;; flatpak.md（GL driver 一致性）。
;;;
;;; update policy：'track-branch。
;;;
;;; override policy：(managed-overrides ...)——本 app 只经
;;; Flatpak 分发（Nonguix steam 容器方案已放弃），仓库拥有完整
;;; override 文件：filesystem=/persist/data-nobackup/steam（
;;; direct-access bulk storage；路径 authority 在
;;; (guixcfg system gaming)，目录由其 activation 创建并归还
;;; USER）。NVIDIA PRIME offload 只由 hardware adapter 在 Lenovo
;;; Guix Home 经 (flatpak-applications-with-environments) 追加
;;; （变量语义归 (guixcfg system graphics nvidia) 单一 authority）。
;;;
;;; 消费方式（mutable user state，不属本声明）：游戏属性 →
;;; Launch Options 写 `gamescope -f -- %command%`；需要
;;; gamescope 的游戏在 Compatibility 里选 GE-Proton
;;; (Flatpak)（proton-ge extension）。已知上游边界（gamescope
;;; 仓库 issue #483）：不要用 gamescope --steam 参数。
;;;
;;; persistence：默认 ~/.var/app/com.valvesoftware.Steam 由 ID
;;; 推导（service 投影）。
;;;
;;; desktop shadow：Steam launcher 1.0.0.66..1.0.0.87（2020-2026）
;;; 的 19 个 stable archive 只有 4 种 desktop 内容；Categories 自
;;; 2015 起一直是 Network;FileTransfer;Game;。Noctalia 对多 main
;;; category 取第一个，误归 Internet，因此本 definition 拥有完整
;;; Flatpak export shadow，仅改 Categories=Game;。来源基线：Flathub
;;; export / steam-launcher 1.0.0.87；升级 launcher 时人工 diff。

(define-module (guixcfg flatpak applications steam definition)
               #:use-module (guix gexp) ; local-file
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg system gaming) ; %steam-games-library-path
               #:export (%flatpak-steam))

(define %flatpak-steam
  (flatpak-application
   (name 'steam)
   (id "com.valvesoftware.Steam")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (desktop-files
    (list (list "com.valvesoftware.Steam.desktop"
                (local-file "com.valvesoftware.Steam.desktop"
                            "steam-flatpak-desktop-shadow.desktop"))))
   (override-policy
    (list 'managed-overrides
          (flatpak-override
           (filesystems (list %steam-games-library-path)))))))
