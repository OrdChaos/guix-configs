;;; Wayland desktop 系统层（M2）：greetd login manager。GPU-neutral——
;;; 本模块不知道任何具体 GPU vendor/driver（vendor 相关内容见
;;; graphics adapter module）。
;;;
;;; 登录链（docs/architecture/graphics.md）：
;;;   interactive-session-ready（core readiness join barrier）
;;;     ├─ greetd（tty1，requirement 含 interactive-session-ready）
;;;     └─ mingetty fallback（tty2，同样 gated——core readiness 失败
;;;        时两条路径都不绕过 barrier；desktop 失败时 tty2 仍可用）
;;;   greetd → default_session = greetd-noctalia-session（channel
;;;     helper wrapper；greeter 用户，HOME=/var/empty）→ wrapper 以
;;;     真实 store 路径为 argv0 exec upstream noctalia-greeter-
;;;     session（$0 相对前缀语义保留）→ noctalia-greeter-compositor
;;;     （自带 wlroots compositor，不套 Sway/Cage）→ noctalia-greeter
;;;     UI → 用户认证（greetd PAM）→ IPC StartSession：
;;;       cmd = 会话 .desktop 的 Exec（niri.desktop =
;;;       <store>/bin/bash -l，见 (guixcfg system noctalia-greeter)）
;;;       env = XDG_SESSION_TYPE=wayland / XDG_CURRENT_DESKTOP /
;;;       XDG_SESSION_DESKTOP（greeter 发送，sessionStartEnvironment）
;;;     → greetd session worker（root）：PAM → getpwnam(认证用户)
;;;     → HOME/USER/LOGNAME/SHELL = passwd entry → execve(/bin/sh
;;;     -c "exec bash -l", PAM envlist + IPC env) → bash -l
;;;     → Guix Home（bash_profile → on-first-login → Home Shepherd →
;;;     官方 Home D-Bus / Home Niri / Home PipeWire）。
;;;
;;; ── greeter 运行时环境（channel service，2026-08-28 迁移）──
;;; greeter 会话经 worker execve 整体替换环境，envvec = PAM envlist
;;; （无 PATH——pam_env 无参数只 honor /etc/environment）。upstream
;;; session script 与 greeter 的 power actions 在运行时从 PATH 解析
;;; 命令——该环境现由 virelith channel 的 greetd-noctalia-session
;;; helper 提供（确定性 PATH：coreutils/dbus/elogind；XDG_DATA_DIRS
;;; 指向 system profile share；并以真实 script 路径为 argv0 exec，
;;; 保留 upstream 的 $0 相对前缀语义）。配置仓库不 wrap、不复制、
;;; 不补 env。polkit policy / system profile 注入 / state directory
;;; owner/mode 由 channel 的 noctalia-greeter-service-type 负责；
;;; 本仓库保留 greetd 接线、niri 会话发现数据与 machine-state
;;; persistence（见 (guixcfg system noctalia-greeter) 头部）。
;;;
;;; ── XDG_SESSION_TYPE 契约（2026-08-28，greeter 切换）──
;;; 旧链（agreety）里 pam_elogind 在 PAM envlist 写
;;; XDG_SESSION_TYPE=tty（PAM 只知道 tty 会话），官方 greetd
;;; wrapper（make-greetd-xdg-user-session-command）负责改写 wayland，
;;; 因此 source-profile? #f 保证 wrapper 先于 profile 生效。
;;; noctalia-greeter 原生接管该职责：StartSession 的 env 经
;;; worker.rs 在 pam.open_session **之前** putenv 进 PAM env（pinned
;;; greetd 0.10.3 worker.rs:220-226 env.iter().chain(prepared_env)），
;;; pam_elogind（257.16 pam_elogind.c:1024 getenv_harder）读到
;;; XDG_SESSION_TYPE=wayland → 按 wayland 注册会话并原值回写
;;; （pam_misc_setenv read_only=0，1244 update_environment）——
;;; envlist 里 wayland 从会话开始就在，profile 顺序不再影响
;;; portal 后端。source-profile? #f 保持：profile 由 bash -l
;;; 自行 source（/etc/profile 与 ~/.bash_profile 行为不变）。
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
;;;   - noctalia-greeter 经 IPC 只发 cmd + sessionStartEnvironment
;;;     （XDG_SESSION_TYPE/CURRENT_DESKTOP/SESSION_DESKTOP）——
;;;     IPC 无其他泄漏通道（greetd_client.cpp requestStartSession）。
;;; PAM 与 Guix 侧都不设置 HOME：
;;;   - unix-pam-service（gnu/system/pam.scm:216-290）的 pam_env.so
;;;     无参数、只 honor /etc/environment（本机为空，未定义
;;;     session-environment）——没有 HOME 规则；
;;;   - pam_elogind（elogind 257.16 elogind-compat，
;;;     src/login/pam_elogind.c:814, 1226-1277）只设
;;;     XDG_RUNTIME_DIR/XDG_SESSION_*/XDG_SEAT/XDG_VTNR（257.16 实测
;;;     核对：XDG_RUNTIME_DIR 在 814 setenv 与 1231 用户匹配守卫，
;;;     SESSION_ID/SEAT/VTNR 在 1226-1277；无任何 HOME 设置）；
;;;   - Guix 官方 wrapper（gnu/services/base.scm:3715-3729
;;;     make-greetd-xdg-user-session-command）只设 XDG_SESSION_TYPE
;;;     与 XDG_RUNTIME_DIR（getpwuid($USER)）——本仓库已不再使用
;;;     该 wrapper（greeter 原生提供 XDG env，见上）。
;;; 测试固定见 tests/test-desktop.scm "HOME provenance" 组。

(define-module (guixcfg system desktop)
               #:use-module (gnu services)            ; service
               #:use-module (gnu services base)       ; greetd-service-type、greetd-configuration、greetd-terminal-configuration
               #:use-module (virelith services noctalia-greeter) ; noctalia-greeter-service-type、noctalia-greeter-configuration、greetd-noctalia-session
               #:use-module (guixcfg system noctalia-greeter) ; %noctalia-greeter-state-dir、noctalia-greeter-session-profile-service
               #:export (desktop-services))

;;; ────────────────────────────────────────────────────────────
;;; greetd：tty1，gated by interactive-session-ready，
;;; noctalia-greeter greeter（channel helper 启动），无 autologin。
;;;
;;; default-session-command 语义 = greeter（greetd config.toml：
;;; "The default session, also known as the greeter"）。入口是
;;; virelith channel 的 greetd-noctalia-session helper：它为
;;; greeter 会话提供确定性 PATH/XDG_DATA_DIRS，并以真实
;;; noctalia-greeter-session 的 store 路径为 argv0 exec（upstream
;;; 以 dirname "$0" 相对定位同 prefix 的 compositor/greeter——
;;; 配置仓库不直接 file-append、不 wrap、不复制）。greetd 0.10.3
;;; start_greeter 把 command 作为单个 argv 交给 sh -c exec
;;; （config 无空格 store 路径安全）。
;;;
;;; 用户认证后的会话不再经 agreety wrapper：greeter 自己经 greetd
;;; IPC 发送 .desktop Exec + XDG env（见文件头登录链与
;;; (guixcfg system noctalia-greeter) 的会话发现数据）。
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
               ;; source-profile? #f：用户会话 profile 单次 source
               ;; 语义见文件头 "XDG_SESSION_TYPE 契约" 审计
               ;; （greeter 原生提供 wayland env，profile 改由
               ;; bash -l 自行 source）。greeter 自身的环境由
               ;; channel helper 提供，与本开关无关——不因 helper
               ;; 自带 env 而改动 profile policy。
               (source-profile? #f)
               ;; Noctalia Greeter 的 greetd entry point（channel
               ;; helper wrapper，非裸 upstream script；greeter 以
               ;; greetd 的 greeter 用户无认证运行——start_greeter
               ;; authenticate=false，HOME=/var/empty）。
               ;; 光标异常（倒置 + 登录后幽灵光标）最终确认为宿主
               ;; virglrenderer 的 bug（virtio GPU 的宿主 GL 后端），
               ;; 与 greeter 无关——virelith channel 的 cursor patch
               ;; 已回滚，package 保持 unpatched 上游状态。排查记录
               ;; 见 docs/operations/vm-testing.md「光标异常排查记录」。
               (default-session-command
                (greetd-noctalia-session))))))))

(define desktop-services
  ;; M2 Wayland desktop 系统层服务。Noctalia Greeter 的通用系统
  ;; 集成（polkit policy / system profile / state directory）由
  ;; virelith channel 的 noctalia-greeter-service-type 提供——
  ;; state-directory 显式绑定本仓库的机器策略路径（persistence
  ;; rule consumer 同源，避免双份字面量漂移）。用户会话内的服务
  ;; （PipeWire、notification、polkit agent 等）由 niri config 的
  ;; spawn-at-startup 以用户身份启动（单一 owner = niri session，
  ;; 见 modules/guixcfg/apps/niri/config.kdl 与
  ;; docs/architecture/graphics.md）。
  (list (greetd-login-service)
        (service noctalia-greeter-service-type
                 (noctalia-greeter-configuration
                  (state-directory %noctalia-greeter-state-dir)))
        ;; repo-owned 登录会话发现数据（niri.desktop）→ system
        ;; profile（greeter 的会话发现路径）。
        (noctalia-greeter-session-profile-service)))
