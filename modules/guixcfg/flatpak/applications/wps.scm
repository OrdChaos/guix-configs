;;; WPS Office 365 application definition（Flatpak；docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 自包含 definition：identity / Flatpak ref metadata / update
;;; policy / override policy / persistence intent 全部属于本文件；
;;; registry 只聚合（(guixcfg flatpak registry)），selection 只
;;; 选择 logical name，service/reconcile 从 definition 投影。
;;;
;;; 选型理由：WPS Office 365（国产办公套件，文档兼容性优先于
;;; ONLYOFFICE；专有二进制，天然适合 Flatpak 分发）。app-id 用
;;; cn.wps.wps_365（Flathub 现行 listing "WPS 365"；旧的
;;; com.wps.Office 不用），app-id/branch 以 Flathub 官方核实
;;; （flathub.org/apps/cn.wps.wps_365，branch=stable；extra-data
;;; 打包，runtime org.freedesktop.Platform 25.08）。
;;;
;;; update policy：'track-branch（默认策略；如需 pin 改为
;;; (flatpak-commit-pin "...") 并注释理由）。
;;;
;;; override policy：'external——先以上游 manifest 权限运行；实机
;;; 验证发现真正需要的 delta 后，按 Flatseal 实验工作流
;;; （flatpak.md（overrides））改为 (managed-overrides ...) 回填。
;;; 注意上游 manifest 无 wayland socket（X11 经 xwayland-satellite
;;; 运行，会话已有）。
;;;
;;; persistence：默认 ~/.var/app/cn.wps.wps_365 由 ID 推导
;;; （service 投影，无需在此声明）——Kingsoft 配置/备份/云文档
;;; 状态全部在 XDG_CONFIG_HOME/XDG_DATA_HOME 下（flathub
;;; wps_runner.sh 核实），沙箱内 XDG 路径即该目录。
;;;
;;; MIME/默认应用边界（AGENT.md §Application layer）：本模块只描述
;;; WPS 是什么；"是否被选作默认办公应用"是用户级策略，属于统一
;;; XDG/default-apps 模块 (guixcfg home xdg)——它消费
;;; %wps-desktop-entry 生成 mimeapps.list 的
;;; [Default Applications]（依赖方向 policy → app metadata，
;;; 本模块不反向依赖 xdg）。

(define-module (guixcfg flatpak applications wps)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-wps
                         %wps-desktop-entry))

(define %flatpak-wps
  (flatpak-application
   (name 'wps)
   (id "cn.wps.wps_365")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy 'external)))

;; WPS 的 XDG desktop entry 名：Flatpak exports 机制把应用的主
;; desktop 文件以 <app-id>.desktop 固定命名导出到
;; exports/share/applications/（flathub appstream launchable 核实：
;; desktop-id = cn.wps.wps_365.desktop）。纯数据常量（从 ID 推导，
;; single source）：供统一 XDG 策略模块引用，不在此决定默认应用。
(define %wps-desktop-entry
  (string-append (flatpak-application-id %flatpak-wps) ".desktop"))
