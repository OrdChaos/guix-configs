;;; Discord application definition（Flatpak；docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 自包含 definition：identity / Flatpak ref metadata / update
;;; policy / override policy / persistence intent 全部属于本文件；
;;; registry 只聚合（(guixcfg flatpak registry)），selection 只
;;; 选择 logical name，service/reconcile 从 definition 投影。
;;;
;;; 选型理由：Discord（Electron 桌面客户端；Guix 无对应包，上游
;;; 更新频繁，天然适合 Flatpak 分发）。app-id/branch 以 Flathub
;;; 官方 appstream 核实（flathub.org/apps/com.discordapp.Discord，
;;; ref app/com.discordapp.Discord/x86_64/stable，非 EOL）。
;;;
;;; 已知上游边界（Flathub 描述）：沙箱默认禁用 Game Activity /
;;; 任意文件访问 / Rich Presence；需要时按 Flatseal 工作流在
;;; override 层评估，不要预置放宽。
;;;
;;; update policy：'track-branch（默认策略；如需 pin 改为
;;; (flatpak-commit-pin "...") 并注释理由）。
;;;
;;; override policy：'external——先以上游 manifest 权限运行；实机
;;; 验证发现真正需要的 delta 后，按 Flatseal 实验工作流
;;; （flatpak.md（overrides））改为 (managed-overrides ...) 回填。
;;;
;;; persistence：默认 ~/.var/app/com.discordapp.Discord 由 ID 推导
;;; （service 投影，无需在此声明）；extra-persistence 只声明默认
;;; 之外的例外。

(define-module (guixcfg flatpak applications discord definition)
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-discord))

(define %flatpak-discord
  (flatpak-application (name 'discord)
                       (id "com.discordapp.Discord")
                       (remote 'flathub)
                       (branch "stable")
                       (update-policy 'track-branch)
                       (override-policy 'external)))
