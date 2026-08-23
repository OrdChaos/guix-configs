;;; 桌面外观共享事实（appearance facts）：GTK/Noctalia/niri/
;;; xsettingsd 共同消费的单一事实来源（任务十五——同一组值不得在
;;; 多个模块散落，也不为它们建框架）。
;;;
;;; 所有主题名均从构建产物实测，不凭包名猜测（2026-08，pinned
;;; virelith 60fbe17 / guix b5ff8a00）：
;;;   - adw-gtk3-theme 5.10（(gnu packages gnome-xyz)）share/themes/
;;;     下实际目录：adw-gtk3（light）、adw-gtk3-dark；
;;;   - fluent-icon-theme（(virelith packages icons)）share/icons/
;;;     实际目录含 Fluent / Fluent-light / Fluent-dark + 颜色变体；
;;;     图标不随 Light/Dark 切换（任务八），固定 Fluent-light
;;;     （Arch 实机同款）；
;;;   - fluent-cursor-theme（(virelith packages cursors)）
;;;     share/icons/ 实际目录：Fluent-cursors、Fluent-dark-cursors
;;;     （与 niri common.kdl 既有 cursor 块一致）；
;;;   - UI font：仓库无独立"带字号 UI 字体"权威——(guixcfg home
;;;     fonts) 只拥有 fontconfig generic/fallback 策略，应用层消费
;;;     generic alias（"Sans Serif" → MiSans 主链）。字号 11 对齐
;;;     Arch 实机 GTK 习惯；
;;;   - 默认 mode：'light——与 Noctalia seed 的 [theme] mode =
;;;     "light" 一致（Noctalia 是运行时 mode 权威；本值是静态
;;;     fallback / session 起点 reconcile 目标）。
;;;
;;; 消费方：apps/gtk（settings.ini + gtk.css + appearance-sync）、
;;; apps/xsettingsd（session wrapper）。niri 的 cursor 块是静态
;;; kdl，无法插值——按注释交叉引用（值变更需同步两边）。

(define-module (guixcfg home appearance)
               #:export (%appearance-gtk-theme-light
                         %appearance-gtk-theme-dark
                         %appearance-icon-theme
                         %appearance-cursor-theme
                         %appearance-cursor-size
                         %appearance-ui-font
                         %appearance-default-mode))

(define %appearance-gtk-theme-light "adw-gtk3")
(define %appearance-gtk-theme-dark "adw-gtk3-dark")
(define %appearance-icon-theme "Fluent-light")
(define %appearance-cursor-theme "Fluent-dark-cursors")
(define %appearance-cursor-size 24)
(define %appearance-ui-font "Sans Serif 11")
(define %appearance-default-mode 'light)  ; 'light | 'dark
