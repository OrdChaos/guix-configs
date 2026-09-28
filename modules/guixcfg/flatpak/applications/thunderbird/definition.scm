;;; Thunderbird application definition（Flatpak；docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 自包含 definition：identity / Flatpak ref metadata / update
;;; policy / override policy / persistence intent 全部属于本文件；
;;; registry 只聚合（(guixcfg flatpak registry)），selection 只
;;; 选择 logical name，service/reconcile 从 definition 投影。
;;;
;;; 选型理由/风险：Thunderbird 邮件客户端（Guix 无对应包）。
;;; app-id/branch 以 Flathub 官方 appstream 核实
;;; （flathub.org/apps/org.mozilla.Thunderbird，
;;; ref app/org.mozilla.Thunderbird/x86_64/stable）。
;;; 注意：Flathub appstream 当前标记 is_eol=true（runtime
;;; org.freedesktop.Platform 24.08，版本 140.10.2esr）——Flathub
;;; 无其它官方 Thunderbird id（net.thunderbird.Thunderbird 不存在），
;;; 故选此 id；upstream 若恢复维护/迁移 id，更新本 definition。
;;; 这是有意接受的维护风险，不是默认安全假设。
;;;
;;; update policy：'track-branch（默认策略；如需 pin 改为
;;; (flatpak-commit-pin "...") 并注释理由）。
;;;
;;; override policy：'external——先以上游 manifest 权限运行；实机
;;; 验证发现真正需要的 delta 后，按 Flatseal 实验工作流
;;; （flatpak.md（overrides））改为 (managed-overrides ...) 回填。
;;;
;;; persistence：默认 ~/.var/app/org.mozilla.Thunderbird 由 ID 推导
;;; （service 投影，无需在此声明）；extra-persistence 只声明默认
;;; 之外的例外。

(define-module (guixcfg flatpak applications thunderbird definition)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-thunderbird))

(define %flatpak-thunderbird
  (flatpak-application
   (name 'thunderbird)
   (id "org.mozilla.Thunderbird")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy 'external)))
