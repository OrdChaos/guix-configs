;;; decibels application unit：GNOME 音频文件播放器（GNOME core）。
;;;
;;; 来源（pinned guix 086bc58f 审计）：decibels 定义于
;;; (gnu packages gnome)；49.0，meson + gjs（TypeScript→GJS），
;;; gstreamer + gst-plugins-bad（GstPlay）播放，libadwaita UI；
;;; 包内 wrap-program 处理 GI_TYPELIB_PATH，install-alias 阶段
;;; 提供 decibels 别名（实际二进制 org.gnome.Decibels）。包自带
;;; desktop entry（data/org.gnome.Decibels.desktop.in.in 实测：
;;; org.gnome.Decibels.desktop，Exec=org.gnome.Decibels %U）。
;;;
;;; 角色边界（docs/architecture/applications.md）：
;;;   - 音频文件播放器（直接打开单个音频文件），默认音频 MIME
;;;     策略归本应用（guixcfg home xdg 单一默认；amberol 是音乐
;;;     库播放器，不抢占文件关联）；
;;;   - 无 persistence rule：无跨会话必须保留的 mutable state
;;;     （播放列表/历史属用户数据层关注）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps decibels definition)
               #:use-module (gnu packages gnome) ; decibels
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%decibels
                         %decibels-desktop-entry))

;; Decibels 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %decibels-desktop-entry "org.gnome.Decibels.desktop")

(define %decibels
  (application
   (name 'decibels)
   (home-packages (list decibels))))
