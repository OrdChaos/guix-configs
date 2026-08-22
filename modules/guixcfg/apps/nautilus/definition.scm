;;; nautilus application unit：GNOME 文件管理器（niri bind Mod+E
;;; spawn "nautilus" "--new-window"）。
;;;
;;; 桌面集成：
;;;   - GLib schemas 随 profile 经 XDG_DATA_DIRS 发现；
;;;   - Wayland 原生，portal 由 niri 会话提供；
;;;   - trash（回收站位置与"移到回收站"）由 gvfs 的 D-Bus daemon
;;;     （org.gtk.vfs.Daemon / gvfsd-trash）提供。nautilus 包把 gvfs
;;;     放在编译期 inputs（非 propagated，不随 nautilus 进 profile）；
;;;     D-Bus activation 按 XDG_DATA_DIRS 扫描 share/dbus-1/services
;;;     ——gvfs 必须显式进 profile 才能激活 trash 后端（pinned
;;;     guix 3dc50d9 审计）。trash 内容持久化属用户数据
;;;     （user-persistence 的 .local/share/Trash，docs/architecture/
;;;     home.md）。
;;;
;;; 无 persistence 规则（nautilus 状态属用户数据层）。

(define-module (guixcfg apps nautilus definition)
               #:use-module (gnu packages gnome) ; nautilus、gvfs
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%nautilus))

(define %nautilus
  (application
   (name 'nautilus)
   ;; gvfs：trash 的 D-Bus activation 服务文件所在包（见上）。
   (home-packages (list nautilus gvfs))))
