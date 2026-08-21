;;; nautilus application unit：GNOME 文件管理器（niri bind Mod+E
;;; spawn "nautilus" "--new-window"）。
;;;
;;; 桌面集成（既有会话已满足，无新增）：GLib schemas 随 profile 经
;;; XDG_DATA_DIRS 发现；Wayland 原生，portal 由 niri 会话提供。
;;; 无 persistence 规则（nautilus 状态属用户数据层）。

(define-module (guixcfg apps nautilus definition)
               #:use-module (gnu packages gnome) ; nautilus
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%nautilus))

(define %nautilus
  (application
   (name 'nautilus)
   (home-packages (list nautilus))))
