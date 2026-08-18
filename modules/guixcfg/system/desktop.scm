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
               #:export (session-path-helpers
                         niri-wayland-session
                         desktop-services))

;;; ────────────────────────────────────────────────────────────
;;; niri Wayland session（greetd 认证后以用户身份运行）。
;;;
;;; 这是 graphical session 环境的【唯一权威构造点】：
;;;   - PATH = Guix Home profile（用户命令命名空间）+ system profile
;;;     （系统命令）+ 继承的 PAM/安全 PATH（保留）；不依赖任何 shell
;;;     rc / .profile（greetd 的 session 不经过 login shell——§5 实证）；
;;;   - dbus-run-session 与 dbus-daemon 是 bootstrap 基础设施：显式
;;;     store 引用（§2.1），dbus-daemon 不作为 PATH 成员（dbus 不在
;;;     base/Home profile——§35 B 排除）；
;;;   - XDG_RUNTIME_DIR 由 elogind（PAM）建立，缺失即 fail fast。

(define session-path-helpers
  ;; graphical session PATH 构造 helper（单一 gexp——launcher 注入，
  ;; 测试执行同一 runtime code path）。纯 Guile core（不引入 SRFI
  ;; runtime 依赖：login-critical bootstrap 的 runtime bindings 与
  ;; imports 必须一致）。
  #~(begin
      ;; 顺序去重（语义同 SRFI-1 delete-duplicates：保留首次出现）。
      (define (dedupe lst)
        (let loop ((lst lst) (seen '()) (out '()))
          (if (null? lst)
            (reverse out)
            (if (member (car lst) seen)
              (loop (cdr lst) seen out)
              (loop (cdr lst) (cons (car lst) seen)
                    (cons (car lst) out))))))
      ;; 按 : 拆分（跳过空段——PATH 空段等价当前目录，不安全）。
      (define (split-colon s)
        (let loop ((i 0) (start 0) (out '()))
          (cond
           ((>= i (string-length s))
            (reverse (if (< start (string-length s))
                       (cons (substring s start) out)
                       out)))
           ((char=? (string-ref s i) #\:)
            (loop (+ i 1) (+ i 1)
                  (if (> i start)
                    (cons (substring s start i) out)
                    out)))
           (else (loop (+ i 1) start out)))))
      ;; 拼接（空列表 → 空串）。
      (define (join-colon lst)
        (let loop ((lst lst) (acc ""))
          (if (null? lst)
            acc
            (loop (cdr lst)
                  (if (string=? acc "")
                    (car lst)
                    (string-append acc ":" (car lst)))))))))

(define niri-wayland-session
  (program-file
   "niri-wayland-session"
   #~(begin
       #$session-path-helpers
       ;; 1. session-wide PATH：Home profile 在前（用户程序优先）、
       ;;    system profile 次之、继承 PATH 保留（PAM/安全根）。
       ;;    顺序去重（dedupe）——重复无害但保持 PATH 干净；全部
       ;;    纯 Guile core（runtime bindings 与 imports 一致）。
       (let* ((home (or (getenv "HOME")
                        (and=> (false-if-exception (getpwuid (getuid)))
                               passwd:dir)))
              (home-profile (string-append home "/.guix-home/profile/bin"))
              (system-profile "/run/current-system/profile/bin")
              (inherited (or (getenv "PATH") "")))
         (setenv "PATH"
                 (join-colon
                  (dedupe
                   (append (list home-profile system-profile)
                           (split-colon inherited))))))
       ;; 2. elogind 的 PAM 必须已建立 session runtime 目录（非空）。
       (unless (and (getenv "XDG_RUNTIME_DIR")
                    (not (string=? (getenv "XDG_RUNTIME_DIR") "")))
         (error "XDG_RUNTIME_DIR unset: elogind session not established"))
       ;; 3. 单一 user D-Bus session；dbus-daemon 显式 store 引用
       ;;    （bootstrap 依赖，不属于 PATH 命名空间——避免
       ;;    "dbus-daemon: No such file or directory" 类解析失败）。
       (execl #$(file-append dbus "/bin/dbus-run-session")
              "dbus-run-session"
              (string-append "--dbus-daemon="
                             #$(file-append dbus "/bin/dbus-daemon"))
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
