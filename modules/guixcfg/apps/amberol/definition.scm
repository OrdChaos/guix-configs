;;; amberol application unit：GNOME 音乐播放器（GNOME Circle）。
;;;
;;; 来源（pinned guix 086bc58f 审计）：amberol 定义于
;;; (gnu packages gnome-circle)（不是 gnome.scm）；2025.1，
;;; meson + cargo 混合构建（Rust 前端 + GTK4/libadwaita），
;;; gstreamer 播放后端，GST_PLUGIN_SYSTEM_PATH 由包内 wrap-program
;;; 处理。包自带 desktop entry（data/io.bassi.Amberol.desktop.in.in
;;; 实测：io.bassi.Amberol.desktop，Exec=amberol %U）。
;;;
;;; 角色边界（docs/architecture/applications.md）：
;;;   - 音乐库播放器（library/queue 模型），不是文件关联的默认
;;;     音频播放器——默认音频文件策略归 decibels
;;;     （guixcfg home xdg 单一默认；本模块只导出 desktop entry
;;;     纯数据常量供策略层消费，不自行决定默认应用）；
;;;   - 无 persistence rule：播放状态/库是用户数据层关注，
;;;     amberol 无跨会话必须保留的 mutable state（无草稿类数据）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps amberol definition)
               #:use-module (gnu packages gnome-circle) ; amberol
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%amberol
                         %amberol-desktop-entry))

;; Amberol 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %amberol-desktop-entry "io.bassi.Amberol.desktop")

(define %amberol
  (application
   (name 'amberol)
   (home-packages (list amberol))))
