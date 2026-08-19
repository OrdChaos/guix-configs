;;; Wayland desktop 系统层（M2）：greetd login manager。GPU-neutral——
;;; 本模块不知道任何具体 GPU vendor/driver（vendor 相关内容见
;;; graphics adapter module）。
;;;
;;; 登录链（docs/architecture/graphics.md）：
;;;   interactive-session-ready（core readiness join barrier）
;;;     ├─ greetd（tty1，requirement 含 interactive-session-ready）
;;;     └─ mingetty fallback（tty2，同样 gated——core readiness 失败
;;;        时两条路径都不绕过 barrier；desktop 失败时 tty2 仍可用）
;;;   greetd → default_session = agreety greeter（greeter 用户，
;;;     HOME=/var/empty 是 greeter 专用 home）→ 用户认证 →
;;;     IPC StartSession（cmd = 下方 greetd-user-session，env = '()）
;;;     → greetd session worker（root）：PAM → getpwnam(认证用户)
;;;     → HOME/USER/LOGNAME/SHELL = passwd entry（greetd upstream
;;;     设置，非 PAM 非 wrapper）→ execve(session, PAM envlist)
;;;     → greetd-user-session（官方 wrapper，只设置 XDG_*）→ bash -l
;;;     → Guix Home（bash_profile → on-first-login → Home Shepherd →
;;;     官方 Home D-Bus / Home Niri / Home PipeWire——不再有 custom
;;;     session wrapper，见 upstream-boundaries.md）。
;;;
;;; 无 autologin：greetd 走 agreety（内置最小 greeter）+ 既有 account
;;; DB / PAM；空密码禁用（allow-empty-passwords? #f）。
;;;
;;; ── HOME provenance（exact pinned source audit，2026-08-18）──
;;; 用户会话的 HOME 由 greetd 0.10.3 本身设置，契约如下：
;;;   - greetd/src/session/worker.rs:162-164：认证后
;;;     User::from_name(pam_username)（getpwnam）取目标用户 passwd；
;;;   - worker.rs:205-216：prepared_env 把 USER/LOGNAME/HOME/SHELL
;;;     （passwd 的 name/dir/shell）putenv 进 PAM 环境；
;;;   - worker.rs:222 pam.open_session 后 getenvlist（:239），
;;;     fork+setuid（:245-255）后 execve("/bin/sh","-c",
;;;     "exec <session>", envvec)（:267-276）——execve 整体替换环境，
;;;     greeter（HOME=/var/empty）的进程环境【不可能】被继承；
;;;   - agreety/src/main.rs:107-110：StartSession 只发 cmd + env='()'
;;;     （greeter 配置 env，非进程环境）——IPC 无泄漏通道。
;;; PAM 与 Guix 侧都不设置 HOME：
;;;   - unix-pam-service（gnu/system/pam.scm:216-290）的 pam_env.so
;;;     无参数、只 honor /etc/environment（本机为空，未定义
;;;     session-environment）——没有 HOME 规则；
;;;   - pam_elogind（elogind V255.22 src/login/pam_elogind.c:770,
;;;     1190-1228）只设 XDG_RUNTIME_DIR/XDG_SESSION_*/XDG_SEAT/
;;;     XDG_VTNR；
;;;   - Guix 官方 wrapper（gnu/services/base.scm:3715-3729
;;;     make-greetd-xdg-user-session-command）只设 XDG_SESSION_TYPE
;;;     与 XDG_RUNTIME_DIR（getpwuid($USER)）。
;;; 测试固定见 tests/test-desktop.scm "HOME provenance" 组。

(define-module (guixcfg system desktop)
               #:use-module (gnu services)            ; service
               #:use-module (gnu services base)       ; greetd-service-type、greetd-configuration、greetd-terminal-configuration
               #:use-module (gnu system pam)          ; pam-root-service-type、unix-pam-service
               #:use-module (gnu packages bash)      ; bash（greetd-user-session command）
               #:use-module (guix gexp)               ; file-append
               #:export (desktop-services))

;;; ────────────────────────────────────────────────────────────
;;; greetd：tty1，gated by interactive-session-ready，agreety
;;; greeter（greetd 内置，最小 frontend），无 autologin。
;;;
;;; 认证后的用户会话【交给 pinned Guix 官方模型】（docs/architecture/
;;; upstream-boundaries.md）：default-session-command 语义 = greeter
;;; （greetd config.toml："The default session, also known as the
;;; greeter"；Guix 默认值即 (greetd-agreety-session)——
;;; gnu/services/base.scm:4275-4276；Guix 手册 doc/guix.texi
;;; "greetd-service-type"）——必须用 greetd-agreety-session 包装
;;; user-session，它编译为 agreety-wrapper：
;;;   execl agreety agreety -c <greetd-user-session>
;;; （base.scm:3762-3776 greetd-agreety-session-compiler）。
;;; 若把 greetd-user-session 直接放在 default-session-command，greetd
;;; 会把它当作【greeter】以 greeter 用户无认证运行（server.rs
;;; greet()→start_greeter→authenticate=false）——没有登录提示符，
;;; HOME = greeter 的 /var/empty。用户认证后会话由 agreety 经 IPC
;;; 以认证用户启动（见头注释 HOME provenance）。
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
               ;; 官方 greeter 模式：agreety 提示符 + -c 指向认证后
               ;; 的 user-session（bash -l login session，Wayland XDG
               ;; 环境），由 Guix Home 接管用户桌面生命周期（Home
               ;; Shepherd 启动 D-Bus/Niri/PipeWire——
               ;; docs/architecture/upstream-boundaries.md）。
               (default-session-command
                (greetd-agreety-session
                 (command
                  (greetd-user-session
                   (command (file-append bash "/bin/bash"))
                   (command-args '("-l"))
                   (xdg-session-type "wayland")
                   (xdg-env? #t)))))))))))

(define desktop-services
  ;; M2 Wayland desktop 系统层服务（greetd + niri session）。
  ;; 用户会话内的服务（PipeWire、notification、polkit agent 等）由
  ;; niri config 的 spawn-at-startup 以用户身份启动（单一 owner =
  ;; niri session，见 modules/guixcfg/apps/niri/config.kdl 与
  ;; docs/architecture/graphics.md）。
  (list (greetd-login-service)
        ;; greeter 会话专用 PAM service（pinned greetd 0.10.3
        ;; server.rs:209-228：/etc/pam.d/greetd-greeter 存在时 greeter
        ;; 会话用它，否则回退到 general service "greetd"）。guix 只
        ;; 生成 "greetd"——若不加这个文件，greeter 会话会走带
        ;; pam_gnome_keyring 的 "greetd" 栈，每次 greeter 启动都
        ;; spawn 一个 --login stub（实测：SSH-only 轮次出现
        ;; gnome-keyring-daemon --daemonize --login 进程）。
        (simple-service 'greetd-greeter-pam pam-root-service-type
                        (list (unix-pam-service "greetd-greeter")))))
