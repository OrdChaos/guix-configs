;;; Wayland desktop 系统层（M2）：greetd login manager + niri Wayland
;;; session 的会话启动。GPU-neutral——本模块不知道任何具体 GPU
;;; vendor/driver（vendor 相关内容见 graphics adapter module）。
;;;
;;; 登录链（docs/architecture/graphics.md）：
;;;   interactive-session-ready（core readiness join barrier）
;;;     ├─ greetd（tty1，requirement 含 interactive-session-ready）
;;;     └─ mingetty fallback（tty2，同样 gated——core readiness 失败
;;;        时两条路径都不绕过 barrier；desktop 失败时 tty2 仍可用）
;;;   greetd → PAM（unix-pam-service，login-uid?）→ elogind session
;;;     → /run/user/$UID → 本模块的 session wrapper
;;;   session wrapper：单一 user D-Bus（dbus-run-session）→ exec
;;;     niri --session（niri 官方非 systemd 入口）。
;;;
;;; 无 autologin：greetd 走 agreety（内置最小 greeter）+ 既有 account
;;; DB / PAM；空密码禁用（allow-empty-passwords? #f）。

(define-module (guixcfg system desktop)
               #:use-module (gnu services)            ; service
               #:use-module (gnu services base)       ; greetd-service-type、greetd-configuration、greetd-terminal-configuration
               #:use-module (gnu packages glib)       ; dbus（dbus-run-session）
               #:use-module (gnu packages window-management) ; niri
               #:use-module (guix gexp)
               #:export (niri-wayland-session
                         desktop-services))

;;; ────────────────────────────────────────────────────────────
;;; niri Wayland session（greetd 认证后以用户身份运行）。

(define niri-wayland-session
  (program-file
   "niri-wayland-session"
   #~(begin
       ;; 单一 user D-Bus session（dbus-run-session 设置并清理
       ;; DBUS_SESSION_BUS_ADDRESS——不写死静态路径、不重复启动
       ;; session bus）；随后 exec niri --session（niri 26 的官方
       ;; 非 systemd 入口，pinned guix 的 .desktop Exec 同款）。
       (execl #$(file-append dbus "/bin/dbus-run-session")
              "dbus-run-session"
              "--" #$(file-append niri "/bin/niri") "--session"))))

;;; ────────────────────────────────────────────────────────────
;;; greetd：tty1，gated by interactive-session-ready，agreety
;;; greeter（greetd 内置，最小 frontend），无 autologin。

(define (greetd-login-service)
  (service greetd-service-type
           (greetd-configuration
            (allow-empty-passwords? #f)
            (terminals
             (list
              (greetd-terminal-configuration
               (terminal-vt "1")
               ;; core readiness join barrier：login prompt 可见 =
               ;; interactive-session-ready 已过（与 tty2 mingetty
               ;; 同一 invariant）。
               (extra-shepherd-requirement '(interactive-session-ready))
               ;; agreety：greetd 内置最小 greeter（默认值，显式写出
               ;; 以表达选择）。
               (default-session-command niri-wayland-session)))))))

(define desktop-services
  ;; M2 Wayland desktop 系统层服务（greetd + niri session）。
  ;; 用户会话内的服务（PipeWire、notification、polkit agent 等）由
  ;; niri config 的 spawn-at-startup 以用户身份启动（单一 owner =
  ;; niri session，见 files/niri/config.kdl 与
  ;; docs/architecture/graphics.md）。
  (list (greetd-login-service)))
