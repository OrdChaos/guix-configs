;;; ONLYOFFICE application definition（Flatpak；docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 自包含 definition：identity / Flatpak ref metadata / update
;;; policy / override policy / persistence intent 全部属于本文件；
;;; registry 只聚合（(guixcfg flatpak registry)），selection 只
;;; 选择 logical name，service/reconcile 从 definition 投影。
;;;
;;; 历史：仓库曾以 Guix app（modules/guixcfg/apps/onlyoffice/，
;;; Desktop Editors 打包）提供 ONLYOFFICE，后随 Flatpak 平台引入
;;; 而移除；现以 Flatpak 分发重新提供（上游官方打包，更新周期与
;;; 上游一致，沙箱隔离）。app-id/branch 以 Flathub 官方核实
;;; （flathub.org/apps/org.onlyoffice.desktopeditors，branch=stable）。
;;;
;;; update policy：'track-branch（默认策略；如需 pin 改为
;;; (flatpak-commit-pin "...") 并注释理由）。
;;;
;;; override policy：'external——先以上游 manifest 权限运行；实机
;;; 验证发现真正需要的 delta 后，按 Flatseal 实验工作流
;;; （flatpak.md（overrides））改为 (managed-overrides ...) 回填。
;;;
;;; persistence：默认 ~/.var/app/org.onlyoffice.desktopeditors 由
;;; ID 推导（service 投影，无需在此声明）。
;;;
;;; MIME/默认应用边界（AGENT.md §Application layer）：本模块只描述
;;; ONLYOFFICE 是什么；"是否被选作默认办公应用"是用户级策略，属于
;;; 统一 XDG/default-apps 模块 (guixcfg home xdg)——它消费
;;; %onlyoffice-desktop-entry 生成 mimeapps.list 的
;;; [Default Applications]（依赖方向 policy → app metadata，
;;; 本模块不反向依赖 xdg）。

(define-module (guixcfg flatpak applications onlyoffice)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-onlyoffice
                         %onlyoffice-desktop-entry))

(define %flatpak-onlyoffice
  (flatpak-application
   (name 'onlyoffice)
   (id "org.onlyoffice.desktopeditors")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy 'external)))

;; ONLYOFFICE 的 XDG desktop entry 名：Flatpak exports 机制把应用
;; 的 desktop 文件以 <app-id>.desktop 固定命名导出到
;; exports/share/applications/（不随包内文件名变化）。纯数据常量
;; （从 ID 推导，single source）：供统一 XDG 策略模块引用，不在此
;; 决定默认应用。VM acceptance：安装后核对
;; ~/.local/share/flatpak/exports/share/applications/ 下的文件名。
(define %onlyoffice-desktop-entry
  (string-append (flatpak-application-id %flatpak-onlyoffice) ".desktop"))
