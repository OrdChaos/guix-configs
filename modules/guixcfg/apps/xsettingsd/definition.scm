;;; xsettingsd application unit：X11/XWayland GTK 应用的 XSETTINGS
;;; 服务（主题/图标/光标/字号/字体）。
;;;
;;; 语义边界（任务十/十一/十二）：
;;;   - xsettingsd 只为 X11/XWayland 客户端服务；Wayland 原生 GTK
;;;     读 settings.ini + portal，与它无关；
;;;   - 配置是 runtime derived state：Net/ThemeName 跟随 Light/Dark
;;;     → 配置放 $XDG_RUNTIME_DIR/guixcfg/xsettingsd.conf（ephemeral
;;;     tmpfs），由 appearance-sync（apps/gtk）按 mode 原子重建 +
;;;     SIGHUP reload（pinned xsettingsd 1.0.2：SIGHUP → select
;;;     EINTR → LoadConfig 重发，settings_manager.cc 实测；禁止
;;;     killall——pidfile 精确寻址）。仓库不落永久 XSETTINGS 配置
;;;     文件（~/.xsettingsd 是默认路径，本单元不用它——避免第二个
;;;     authority）；
;;;   - 生命周期 owner = niri session（spawn-at-startup
;;;     "xsettingsd-session"）：spawn 继承会话环境（含 niri 导出的
;;;     $DISPLAY——pinned niri 26.04 wiki：创建 X11 socket 并导出
;;;     DISPLAY、on-demand spawn xwayland-satellite）。不猜
;;;     DISPLAY、不写死 :0、不 sleep 轮询；
;;;   - wrapper 职责：登录时先按声明默认 mode 跑 appearance-sync
;;;     （runtime state 从声明重新收敛，不依赖历史——任务十六），
;;;     写 pidfile（exec 后 xsettingsd 继承 PID），再 exec
;;;     xsettingsd -c <runtime config>。
;;;
;;; XSETTINGS 键（pinned 1.0.2 config_parser 语法 + GTK XSETTINGS
;;; 约定）：Net/ThemeName、Net/IconThemeName、Gtk/CursorThemeName、
;;; Gtk/CursorThemeSize、Gtk/FontName。不加 Xft/*（仓库无 X11 字体
;;; 渲染 policy——XSETTINGS 缺省时 Xft 回落 fontconfig，已统一）。

(define-module (guixcfg apps xsettingsd definition)
               #:use-module (gnu home services)      ; home-files-service-type
               #:use-module (gnu packages xdisorg)   ; xsettingsd
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; program-file、file-append
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg home appearance) ; %appearance-default-mode
               #:export (%xsettingsd
                         %xsettingsd-session-wrapper)) ; 测试需要真实执行

;; 会话 wrapper（纯 Guile core binding——AGENT.md §3 审计面）：
;; reconcile → pidfile → exec。appearance-sync 经会话 PATH 解析
;; （apps/gtk 提供，~/.local/bin 由 apps/polkit-gnome 的 PATH
;; 贡献覆盖）。
(define %xsettingsd-session-wrapper
  (program-file
   "xsettingsd-session"
   #~(begin
      (define runtime-dir (getenv "XDG_RUNTIME_DIR"))
      (when (or (not runtime-dir) (string=? runtime-dir ""))
        (format (current-error-port)
                "xsettingsd-session: XDG_RUNTIME_DIR is not set~%")
        (exit 1))
      ;; DISPLAY 有界等待（最长 ~5s）：niri 的 X11 socket 初始化与
      ;; spawn-at-startup 无显式顺序保证；超时则由 xsettingsd 自身
      ;; 连接失败报错退出（fail visible，不吞错）。
      (let loop ((tries 50))
        (when (and (not (getenv "DISPLAY")) (> tries 0))
          (usleep 100000)
          (loop (- tries 1))))
      ;; 登录 reconcile：声明默认 mode → GSettings/dconf +
      ;; xsettingsd.conf（runtime derived state 全量重建）。
      (unless (zero? (system* "appearance-sync"
                              #$(symbol->string %appearance-default-mode)))
        (format (current-error-port)
                "xsettingsd-session: appearance reconcile failed~%"))
      ;; pidfile 供 appearance-sync 的 SIGHUP reload 寻址
      ;; （exec 保持 PID）。
      (let ((dir (string-append runtime-dir "/guixcfg")))
        (catch 'system-error (lambda () (mkdir dir)) (lambda (key . rest) #t))
        (call-with-output-file (string-append dir "/xsettingsd.pid")
                               (lambda (port) (display (getpid) port))))
      (execl #$(file-append xsettingsd "/bin/xsettingsd")
             "xsettingsd" "-c"
             (string-append runtime-dir "/guixcfg/xsettingsd.conf")))))

(define %xsettingsd
  (application
   (name 'xsettingsd)
   (home-packages (list xsettingsd))
   (home-services
    (list (simple-service 'xsettingsd-session-wrapper
                          home-files-service-type
                          `((".local/bin/xsettingsd-session"
                             ,%xsettingsd-session-wrapper)))))))
