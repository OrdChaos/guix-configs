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
;;; override 文件：
;;;   - filesystem=/persist/data-nobackup/steam：游戏库
;;;     （direct-access bulk storage；路径 authority 在
;;;     (guixcfg system gaming)，目录由其 activation 创建并
;;;     归还 USER）；
;;;   - environment：NVIDIA PRIME offload（投影自
;;;     %prime-offload-environment-strings——变量语义归
;;;     (guixcfg system graphics nvidia) 单一 authority）。
;;;
;;; 消费方式（mutable user state，不属本声明）：游戏属性 →
;;; Launch Options 写 `gamescope -f -- %command%`；需要
;;; gamescope 的游戏在 Compatibility 里选 GE-Proton
;;; (Flatpak)（proton-ge extension）。已知上游边界（gamescope
;;; 仓库 issue #483）：不要用 gamescope --steam 参数。
;;;
;;; Host enablement：本 definition 含 NVIDIA PRIME override——
;;; 只适合有 nvidia 的 host；selection 由 host 决定（lenovo
;;; 选入，VM 缺省不选）。steam-devices udev rules 与游戏库
;;; 目录 activation 属 host 基础设施（(guixcfg system gaming)），
;;; 不随本 definition。
;;;
;;; persistence：默认 ~/.var/app/com.valvesoftware.Steam 由 ID
;;; 推导（service 投影）。

(define-module (guixcfg flatpak applications steam)
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg system graphics nvidia) ; %prime-offload-environment-strings
               #:use-module (guixcfg system gaming)          ; %steam-games-library-path
               #:export (%flatpak-steam))

(define %flatpak-steam
  (flatpak-application
   (name 'steam)
   (id "com.valvesoftware.Steam")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy
    (list 'managed-overrides
          (flatpak-override
           (filesystems (list %steam-games-library-path))
           (environment %prime-offload-environment-strings))))))
