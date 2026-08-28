;;; gtk application unit：GTK3/GTK4 桌面外观（adw-gtk3 + Fluent
;;; 图标/光标 + Noctalia 动态配色入口 + appearance-sync 运行时
;;; mode 同步工具）。
;;;
;;; Ownership（每个最终静态文件恰好一个 publisher；任务二）：
;;;   - 静态声明（repo-owned，home-files，.config 前缀）：
;;;     gtk-3.0/{settings.ini,gtk.css} 与 gtk-4.0/{settings.ini,
;;;     gtk.css}。两个 gtk.css 只有一行 @import noctalia.css——
;;;     GTK 相对 import 按 CSS 文件所在目录解析；文本与 Noctalia
;;;     stock hook 写入的逐字节一致，因此其 ensure_gtk_css_import
;;;     检查恒为 no-op，绝不触发它对 store symlink 的删除/重建
;;;     路径（pinned noctalia apply.sh 审计）；
;;;   - Noctalia 只生成 gtk-{3,4}/noctalia.css（runtime derived
;;;     artifact：palette + template → noctalia.css；不持久化；
;;;     删除后下次 template apply 自动重建）——它永不写 gtk.css；
;;;   - settings.ini 是 Light fallback（声明默认 mode = light）——
;;;     但注意 settings.ini 只是【部分通道】的 source（2026-08 pinned
;;;     源码审计）：
;;;       * GTK3 on Wayland 对 translated 键（gtk-theme-name、
;;;         icon/cursor/font 等）完全不看 settings.ini——直读
;;;         GSettings org.gnome.desktop.interface（gtk+-3.24.51
;;;         gdk/wayland/gdkscreen-wayland.c translations[]）；
;;;       * GTK4 on Wayland 在 portal 可用时经 portal Settings 读同
;;;         一组键（gtk-4.22.1 gdk/gdk.c：portal 可用即用，
;;;         非仅 sandbox）；portal gnome backend 读 dconf；
;;;       * settings.ini 的实际消费者：GTK4 无 portal 时的 fallback、
;;;         Qt 的 gtk3 platform theme（noctalia 经它读图标主题）；
;;;       * X11/XWayland：XSETTINGS（apps/xsettingsd）。
;;;     因此权威下发点 = appearance-sync 写 dconf（runtime derived
;;;     state，不是 source of truth；每次登录由 apps/xsettingsd 的
;;;     session wrapper 按声明默认 reconcile，Noctalia mode 切换时经
;;;     post-hook 重写）；settings.ini 保留为无 portal/dconf 环境的
;;;     fallback，运行时永不改写。
;;;
;;; appearance-sync（~/.local/bin，runtime mode 同步工具，不是
;;; 配置权威）：light|dark →
;;;   1. GSettings org.gnome.desktop.interface 全量键：
;;;      color-scheme=prefer-<mode>、gtk-theme=<adw-gtk3|
;;;      adw-gtk3-dark>（随 mode），icon-theme、cursor-theme、
;;;      cursor-size、font-name（静态，不随 mode）——dconf 是
;;;      runtime derived state，每次登录从声明 reconcile；
;;;   2. 原子重建 $XDG_RUNTIME_DIR/guixcfg/xsettingsd.conf
;;;      （tmp+rename；XSETTINGS 键语法经 pinned xsettingsd 1.0.2
;;;      config_parser 核实：字符串带引号、整数裸写）；
;;;   3. 读 pidfile SIGHUP 当前会话的 xsettingsd（pinned 1.0.2
;;;      settings_manager.cc：SIGHUP → select EINTR → reload；
;;;      精确 PID，禁止 killall）。
;;;   调用方：xsettingsd-session wrapper（登录 reconcile）与
;;;   Noctalia template post-hook（mode 切换）。
;;;   2. 原子重建 $XDG_RUNTIME_DIR/guixcfg/xsettingsd.conf
;;;      （tmp+rename；XSETTINGS 键语法经 pinned xsettingsd 1.0.2
;;;      config_parser 核实：字符串带引号、整数裸写）；
;;;   3. 读 pidfile SIGHUP 当前会话的 xsettingsd（pinned 1.0.2
;;;      settings_manager.cc：SIGHUP → select EINTR → reload；
;;;      精确 PID，禁止 killall）。
;;;   调用方：xsettingsd-session wrapper（登录 reconcile）与
;;;   Noctalia template post-hook（mode 切换）。
;;;
;;; 包：adw-gtk3-theme（share/themes/adw-gtk3{,-dark} 实测）、
;;; fluent-icon-theme/fluent-cursor-theme（Virelith；目录名
;;; Fluent-light / Fluent-dark-cursors 实测）、
;;; gsettings-desktop-schemas（org.gnome.desktop.interface schema，
;;; gsettings CLI 与 portal gnome backend 都需要）、dconf
;;; （ca.desktop.dconf D-Bus 服务 + CLI）、glib bin（gsettings CLI）。
;;;
;;; 明确不做：GTK2/.gtkrc-2.0、~/.icons/default/index.theme、
;;; 第三方 GTK4 structural theme、gtk-xft-*/gtk-im-module/
;;; gtk-application-prefer-dark-theme（无明确需求）；GTK4 不设
;;; gtk-theme-name（保持原生 Adwaita/libadwaita 结构）。

(define-module (guixcfg apps gtk definition)
               #:use-module (gnu home services)      ; xdg-config、home-files
               #:use-module (gnu packages glib)      ; glib（bin 输出：gsettings）
               #:use-module (gnu packages gnome)     ; gsettings-desktop-schemas、dconf
               #:use-module (gnu packages gnome-xyz) ; adw-gtk3-theme
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; plain-file、program-file
               #:use-module (guix records)
               #:use-module (virelith packages icons)   ; fluent-icon-theme
               #:use-module (virelith packages cursors) ; fluent-cursor-theme
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg home appearance)  ; 共享外观事实
               #:export (%gtk
                         %appearance-sync))           ; 测试需要真实执行

;; gtk-{3,4}/gtk.css 唯一职责：导入 Noctalia 生成的动态配色
;; （同目录 noctalia.css）。与 stock hook 写入文本逐字节一致。
(define %gtk-css-import
  (plain-file "gtk.css" "@import url(\"noctalia.css\");\n"))

(define (settings-ini name entries)
  "由共享事实生成 settings.ini（单一来源，不散落——任务十五）。"
  (plain-file
   name
   (string-append
    "[Settings]\n"
    (apply string-append
      (map (lambda (pair)
             (string-append (car pair) "=" (cdr pair) "\n"))
           entries)))))

;; GTK3：含 adw-gtk3 主题（静态 Light fallback；运行时切换经
;; GSettings，不改写本文件）。
(define %gtk3-settings
  (settings-ini
   "gtk3-settings.ini"
   `(("gtk-theme-name" . ,%appearance-gtk-theme-light)
     ("gtk-icon-theme-name" . ,%appearance-icon-theme)
     ("gtk-cursor-theme-name" . ,%appearance-cursor-theme)
     ("gtk-cursor-theme-size" . ,(number->string %appearance-cursor-size))
     ("gtk-font-name" . ,%appearance-ui-font))))

;; GTK4/libadwaita：无 gtk-theme-name（原生结构）；dark mode 走
;; portal color-scheme，不写 gtk-application-prefer-dark-theme。
(define %gtk4-settings
  (settings-ini
   "gtk4-settings.ini"
   `(("gtk-icon-theme-name" . ,%appearance-icon-theme)
     ("gtk-cursor-theme-name" . ,%appearance-cursor-theme)
     ("gtk-cursor-theme-size" . ,(number->string %appearance-cursor-size))
     ("gtk-font-name" . ,%appearance-ui-font))))

;; runtime appearance 同步工具。全部 Guile core binding + gexp 内
;; 显式 import（AGENT.md §3 审计面）；gsettings 经会话 PATH 解析
;; （glib bin 在本单元 home-packages）。
(define %appearance-sync
  (program-file
   "appearance-sync"
   #~(begin
      (define (usage)
        (format (current-error-port)
                "usage: appearance-sync (light|dark)~%")
        (exit 2))
      (define args (command-line))
      (unless (= (length args) 2) (usage))
      (define mode (cadr args))
      (define theme
        (cond ((string=? mode "light") #$%appearance-gtk-theme-light)
          ((string=? mode "dark") #$%appearance-gtk-theme-dark)
          (else (usage))))
      ;; 1. GSettings org.gnome.desktop.interface 全量键（GTK3
      ;;    on Wayland 直读 GSettings；GTK4 经 portal Settings 读同一
      ;;    组——pinned 审计见文件头）。color-scheme/gtk-theme 随
      ;;    mode，icon/cursor/font 不随 mode。无 session bus /
      ;;    schema 缺失时只警告不中断——xsettingsd 部分仍须完成。
      (for-each
       (lambda (pair)
         (catch 'system-error
           (lambda ()
             (unless (zero? (system* "gsettings" "set"
                                     "org.gnome.desktop.interface"
                                     (car pair) (cdr pair)))
               (format (current-error-port)
                       "appearance-sync: gsettings set ~a failed~%"
                       (car pair))))
           (lambda (key . rest)
             (format (current-error-port)
                     "appearance-sync: cannot execute gsettings~%"))))
       (list (cons "color-scheme" (string-append "prefer-" mode))
             (cons "gtk-theme" theme)
             (cons "icon-theme" #$%appearance-icon-theme)
             (cons "cursor-theme" #$%appearance-cursor-theme)
             (cons "cursor-size" (number->string #$%appearance-cursor-size))
             (cons "font-name" #$%appearance-ui-font)))
      ;; 2. 重建 runtime xsettingsd 配置（tmp+rename 原子替换）。
      (define runtime-dir (getenv "XDG_RUNTIME_DIR"))
      (when (or (not runtime-dir) (string=? runtime-dir ""))
        (format (current-error-port)
                "appearance-sync: XDG_RUNTIME_DIR is not set~%")
        (exit 1))
      (define dir (string-append runtime-dir "/guixcfg"))
      (define config (string-append dir "/xsettingsd.conf"))
      (catch 'system-error (lambda () (mkdir dir)) (lambda (key . rest) #t))
      (call-with-output-file (string-append config ".tmp")
                             (lambda (port)
                               (for-each
                                (lambda (line) (display line port) (newline port))
                                (list
                                 (string-append "Net/ThemeName \"" theme "\"")
                                 (string-append "Net/IconThemeName \""
                                                #$%appearance-icon-theme "\"")
                                 (string-append "Gtk/CursorThemeName \""
                                                #$%appearance-cursor-theme "\"")
                                 (string-append "Gtk/CursorThemeSize "
                                                (number->string #$%appearance-cursor-size))
                                 (string-append "Gtk/FontName \"" #$%appearance-ui-font "\"")))
                               (fsync port)))
      (rename-file (string-append config ".tmp") config)
      ;; 3. SIGHUP 当前会话 xsettingsd（pidfile 精确寻址；进程已死
      ;;    或无 pidfile 时跳过——session 起点 reconcile 即此形）。
      (let ((pid-file (string-append dir "/xsettingsd.pid")))
        (when (file-exists? pid-file)
          (let ((pid (call-with-input-file pid-file read)))
            (when (integer? pid)
              (catch 'system-error
                (lambda () (kill pid SIGHUP))
                (lambda (key . rest) #t)))))))))

(define %gtk
  (application
   (name 'gtk)
   (home-packages (list adw-gtk3-theme
                        fluent-icon-theme
                        fluent-cursor-theme
                        gsettings-desktop-schemas
                        dconf
                        (list glib "bin")))
   (home-services
    (list (simple-service 'gtk-appearance-config
                          home-files-service-type
                          `((".config/gtk-3.0/settings.ini" ,%gtk3-settings)
                            (".config/gtk-3.0/gtk.css" ,%gtk-css-import)
                            (".config/gtk-4.0/settings.ini" ,%gtk4-settings)
                            (".config/gtk-4.0/gtk.css" ,%gtk-css-import)))
          (simple-service 'gtk-appearance-sync-tool
                          home-files-service-type
                          `((".local/bin/appearance-sync"
                             ,%appearance-sync)))))))
