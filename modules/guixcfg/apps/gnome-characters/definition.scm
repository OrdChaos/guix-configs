;;; gnome-characters application unit：GNOME Unicode 字符查看器
;;; （GNOME core）。
;;;
;;; 来源（pinned guix 086bc58f 审计）：gnome-characters 定义于
;;; (gnu packages gnome)；48.0，meson + gjs，GTK4 + libadwaita +
;;; libunistring；包内 wrap-program 注入 GI_TYPELIB_PATH（需要
;;; GTK 与 gnome-desktop 的 Typelib 文件——见包定义 wrap 阶段
;;; 注释）。包自带 desktop entry（data/
;;; org.gnome.Characters.desktop.in.in 实测：
;;; org.gnome.Characters.desktop，Exec=gnome-characters；无
;;; MimeType——不做文件关联）。
;;;
;;; 依赖说明（闭包审计，docs 见 apps 任务报告）：本包传递依赖
;;; 含 gnome-desktop【库】（libgnome-desktop，GDesktopEnums
;;; typelib），不是 GNOME 桌面环境；闭包中无 gnome-shell /
;;; gnome-session / gnome-control-center / evolution-data-server
;;; / mutter / gdm——不引入完整 GNOME 桌面。
;;;
;;; 无 persistence rule：字符查看无跨会话必须保留的 mutable
;;; state。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps gnome-characters definition)
               #:use-module (gnu packages gnome) ; gnome-characters
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%gnome-characters
                         %gnome-characters-desktop-entry))

;; GNOME Characters 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %gnome-characters-desktop-entry "org.gnome.Characters.desktop")

(define %gnome-characters
  (application
   (name 'gnome-characters)
   (home-packages (list gnome-characters))))
