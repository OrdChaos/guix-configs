;;; Wayland desktop 系统层（M2）：greetd login manager。GPU-neutral——
;;; 本模块不知道任何具体 GPU vendor/driver（vendor 相关内容见
;;; graphics adapter module）。
;;;
;;; 登录链（docs/architecture/graphics.md）：
;;;   interactive-session-ready（core readiness join barrier）
;;;     ├─ greetd（tty1，requirement 含 interactive-session-ready）
;;;     └─ mingetty fallback（tty2，同样 gated——core readiness 失败
;;;        时两条路径都不绕过 barrier；desktop 失败时 tty2 仍可用）
;;;   greetd → PAM（unix-pam-service，login-uid?）→ elogind session
;;;     → /run/user/$UID → greetd-user-session（官方）→ Guix Home
;;;     （bash_profile → on-first-login → Home Shepherd → 官方
;;;     Home D-Bus / Home Niri / Home PipeWire——不再有 custom
;;;     session wrapper，见 upstream-boundaries.md）。
;;;
;;; 无 autologin：greetd 走 agreety（内置最小 greeter）+ 既有 account
;;; DB / PAM；空密码禁用（allow-empty-passwords? #f）。

(define-module (guixcfg system desktop)
               #:use-module (gnu services)            ; service
               #:use-module (gnu services base)       ; greetd-service-type、greetd-configuration、greetd-terminal-configuration
               #:use-module (gnu packages bash)      ; bash（greetd-user-session command）
               #:use-module (guix gexp)               ; file-append
               #:export (desktop-services))

;;; ────────────────────────────────────────────────────────────
;;; greetd：tty1，gated by interactive-session-ready，agreety
;;; greeter（greetd 内置，最小 frontend），无 autologin。
;;;
;;; 认证后的用户会话【交给 pinned Guix 官方模型】（docs/architecture/
;;; upstream-boundaries.md）：greetd-user-session（官方 abstraction，
;;; command = bash -l）→ ~/.bash_profile（Guix Home 生成：
;;; setup-environment 提供 Home profile PATH；on-first-login 启动
;;; Home Shepherd）→ Home D-Bus / Home Niri / Home PipeWire（官方
;;; Home services）。HOME/PATH/D-Bus 不再由 custom wrapper 处理——
;;; HOME 来自 PAM（pam_env，unix-pam-service 栈）与 bash login
;;; 语义（§7：authenticated account semantics，非硬编码）。

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
               ;; 认证后进入官方 greetd-user-session（bash -l login
               ;; session，Wayland XDG 环境），由 Guix Home 接管
               ;; 用户桌面生命周期（Home Shepherd 启动 D-Bus/Niri/
               ;; PipeWire——docs/architecture/upstream-boundaries.md）。
               (default-session-command
                (greetd-user-session
                 (command (file-append bash "/bin/bash"))
                 (command-args '("-l"))
                 (xdg-session-type "wayland")
                 (xdg-env? #t)))))))))

(define desktop-services
  ;; M2 Wayland desktop 系统层服务（greetd + niri session）。
  ;; 用户会话内的服务（PipeWire、notification、polkit agent 等）由
  ;; niri config 的 spawn-at-startup 以用户身份启动（单一 owner =
  ;; niri session，见 files/niri/config.kdl 与
  ;; docs/architecture/graphics.md）。
  (list (greetd-login-service)))
