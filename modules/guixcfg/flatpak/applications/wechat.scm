;;; WeChat application definition（Flatpak；docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 自包含 definition：identity / Flatpak ref metadata / update
;;; policy / override policy / persistence intent 全部属于本文件；
;;; registry 只聚合（(guixcfg flatpak registry)），selection 只
;;; 选择 logical name，service/reconcile 从 definition 投影。
;;;
;;; 选型理由：微信 Linux（Electron 二进制，Guix 无对应包，上游
;;; 更新频繁，天然适合 Flatpak 分发）。app-id 以 Flathub 官方页面
;;; 核实（flathub.org/apps/com.tencent.WeChat，branch=stable）。
;;;
;;; update policy：'track-branch（默认策略；如需 pin 改为
;;; (flatpak-commit-pin "...") 并注释理由）。
;;;
;;; override policy：'external——先以上游 manifest 权限运行；实机
;;; 验证发现真正需要的 delta 后，按 Flatseal 实验工作流
;;; （flatpak.md（overrides））改为 (managed-overrides ...) 回填。
;;;
;;; persistence：默认 ~/.var/app/com.tencent.WeChat 由 ID 推导
;;; （service 投影，无需在此声明）；extra-persistence 只声明默认
;;; 之外的例外。

(define-module (guixcfg flatpak applications wechat)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-wechat))

(define %flatpak-wechat
  (flatpak-application
   (name 'wechat)
   (id "com.tencent.WeChat")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy 'external)))
