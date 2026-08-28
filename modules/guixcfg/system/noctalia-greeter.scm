;;; Noctalia Greeter 机器策略层（docs/architecture/graphics.md 登录链）。
;;;
;;; 职责划分（2026-08-28 迁移决策记录）：Noctalia Greeter 的**通用
;;; Guix 系统集成**已迁入 virelith channel 的
;;; (virelith services noctalia-greeter)——其
;;; noctalia-greeter-service-type 负责 polkit policy 暴露、package
;;; 进 system profile、state directory 创建/owner/mode；其
;;; greetd-noctalia-session 负责 greeter 会话的确定性 PATH、
;;; XDG_DATA_DIRS 与 argv0 保留语义。配置仓库不再重复这些通用
;;; integration（此前为 channel 缺 service 而手工组合的 polkit
;;; extension / profile 注入 / state activation 已删除）。
;;;
;;; 本模块保留**配置仓库自己的机器策略**：
;;;   - %noctalia-greeter-persistence-rule：无状态根模型下的
;;;     mutable state 持久化（sync.toml / 同步壁纸 / output 状态）——
;;;     /persist/system/state/noctalia-greeter → bind →
;;;     /var/lib/noctalia-greeter（machine-state，docs/architecture/
;;;     machine-state.md）。channel service 的 activation 只修
;;;     consumer 侧 owner/mode（idempotent、不触碰内容、兼容 bind
;;;     mount），backing 的 owner/mode 仍由本仓库声明——bind 语义
;;;     下 mount 后可见权限 = backing 权限，两侧都要 0750
;;;     greeter:greeter（见 persistence rule 下方说明）。
;;;   - %noctalia-greeter-session-data：repo-owned 登录会话发现
;;;     数据（share/wayland-sessions/niri.desktop）——本仓库定义
;;;     有哪些登录 session，不是 channel 职责；经 system profile
;;;     发布（greeter 会话发现搜索
;;;     /run/current-system/sw/share/wayland-sessions，channel
;;;     helper 的 XDG_DATA_DIRS 默认指向 system profile share）。
;;;
;;; greeter.toml 继续不生成（upstream 默认值 + sync.toml，Noctalia
;;; Shell Sync 控制 appearance——见 graphics.md）。

(define-module (guixcfg system noctalia-greeter)
               #:use-module (gnu packages bash)     ; bash（session Exec）
               #:use-module (gnu services)          ; simple-service
               #:use-module (guix build-system trivial)
               #:use-module (guix gexp)             ; file-append
               #:use-module ((guix licenses) #:prefix license:)
               #:use-module (guix modules)          ; source-module-closure
               #:use-module (guix packages)
               #:use-module (guixcfg system machine-state-persistence) ; machine-state-persistence-rule、%machine-state-root
               #:export (%noctalia-greeter-state-dir
                         %noctalia-greeter-persistence-rule
                         %noctalia-greeter-session-data
                         noctalia-greeter-session-profile-service
                         noctalia-greeter-backing-ownership-activation))

;;; ────────────────────────────────────────────────────────────
;;; State dir：/var/lib/noctalia-greeter（greeter.toml +
;;; sync.toml + 同步 wallpaper/output 状态）。

(define %noctalia-greeter-state-dir "/var/lib/noctalia-greeter")

(define %noctalia-greeter-persistence-rule
  ;; mutable state 的 machine-state 持久化声明（backing 归
  ;; /persist/system/state/noctalia-greeter；bind 挂载在 host
  ;; assembly 接线——docs/architecture/machine-state.md，与 mihomo
  ;; 同一模式）。consumer 侧 owner/mode 由 channel service 的
  ;; activation 负责；backing 侧（bind 的权限来源）由本仓库的
  ;; noctalia-greeter-backing-ownership-activation 负责——bind
  ;; 语义：mount 后 consumer 可见 owner/mode = backing 的
  ;; owner/mode，两侧都必须 0750 greeter:greeter（channel
  ;; activation 不管理 backing）。
  (machine-state-persistence-rule
   (name 'noctalia-greeter)
   (backing "noctalia-greeter")
   (consumer %noctalia-greeter-state-dir)))

(define (noctalia-greeter-backing-ownership-activation)
  "activation gexp：只负责 persistence backing 侧
  /persist/system/state/noctalia-greeter 的 mkdir + chown
  greeter:greeter + chmod 0750（bind 的权限来源；consumer 侧由
  channel service 的 activation 负责）。greeter 账号由 Guix
  greetd service 的 account extension 贡献，account projection 在
  activation 早期写 /etc/passwd（vm.scm 顺序审计）——运行时
  read-passwd 解析 uid/gid，不硬编码；缺失 fail-closed。
  mkdir/chown/chmod 幂等、不触碰已存在内容（不覆盖/不迁移
  backing 数据，machine-state 不变量 4）。"
  (with-imported-modules (source-module-closure
                          '((gnu build accounts)   ; read-passwd、password-entry-*
                            (guix build utils)
                            (srfi srfi-1)))        ; find
                         #~(begin
                            (use-modules (gnu build accounts)
                                         (guix build utils)
                                         (srfi srfi-1))
                            (let* ((backing
                                    (string-append #$%machine-state-root
                                                   "/noctalia-greeter"))
                                   (greeter
                                    (find (lambda (entry)
                                            (string=?
                                             (password-entry-name entry)
                                             "greeter"))
                                          (read-passwd "/etc/passwd"))))
                              (unless greeter
                                (error
                                 "noctalia-greeter: greeter account missing \
from /etc/passwd"))
                              (mkdir-p backing)
                              (chown backing
                                     (password-entry-uid greeter)
                                     (password-entry-gid greeter))
                              (chmod backing #o750)
                              #t))))

;;; ────────────────────────────────────────────────────────────
;;; 登录会话发现：niri.desktop（system profile 发布）。

(define %noctalia-greeter-session-data
  ;; repo-owned 会话发现数据。greeter 的会话发现（pinned v1.2.1
  ;; src/greeter/greeter_sessions.cpp）搜索
  ;; /run/current-system/sw/share/wayland-sessions（Guix system
  ;; profile 的硬编码路径）+ XDG_DATA_DIRS 条目；本仓库 niri 是
  ;; home 包、system profile 没有 wayland-sessions 数据——由本
  ;; package 贡献 niri.desktop。不创建 /usr/share FHS 路径。
  ;;
  ;; Name = 会话选择器标签（greeter.toml [session] default 匹配
  ;; 的是该标签而非 .desktop id）；Exec = 用户会话入口（绝对 store
  ;; 路径，greeter 按空白拆分 argv 经 greetd IPC 发送，worker 以
  ;; sh -c exec 运行——不依赖用户 PATH）。
  ;;
  ;; Exec 语义：bash -l → /etc/profile → ~/.bash_profile →
  ;; Guix Home on-first-login → Home Shepherd（dbus/keyring/niri/
  ;; pipewire）——用户会话所有权在 Guix Home（docs/architecture/
  ;; graphics.md）。XDG_SESSION_TYPE=wayland / XDG_CURRENT_DESKTOP /
  ;; XDG_SESSION_DESKTOP 由 greeter 经 greetd IPC env 发送，在
  ;; pam.open_session 之前进入 PAM env，pam_elogind 读后按
  ;; wayland 注册会话。
  (package
    (name "guixcfg-noctalia-greeter-sessions")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      ;; builder 环境：mkdir-p 需要 (guix build utils)——#:modules 入
      ;; closure，body 内 use-modules 显式导入（gexp 不会自动导入）。
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))  ; mkdir-p
          (mkdir-p (string-append #$output "/share/wayland-sessions"))
          (call-with-output-file
              (string-append #$output
                             "/share/wayland-sessions/niri.desktop")
            (lambda (port)
              (display "[Desktop Entry]\n" port)
              (display "Name=niri\n" port)
              (display
               "Comment=Scrollable-tiling Wayland compositor session \
(Guix Home)\n"
               port)
              (format port "Exec=~a -l\n"
                      #$(file-append bash "/bin/bash"))
              (display "Type=Application\n" port)
              (display "DesktopNames=niri\n" port))))))
    (home-page "https://github.com/OrdChaos/guix-configs")
    (synopsis "Wayland session entries for the noctalia-greeter login screen")
    (description
     "Provides share/wayland-sessions desktop entries so that the
noctalia-greeter login screen can discover the host's Wayland sessions.
The niri entry starts the user's login shell, letting Guix Home own the
desktop session lifecycle.")
    (license license:expat)))

(define (noctalia-greeter-session-profile-service)
  "把 repo-owned 会话发现数据（niri.desktop）发布到 system profile
  ——greeter 会话发现路径 /run/current-system/sw/share/
  wayland-sessions 与 channel helper 的 XDG_DATA_DIRS 都指向它。
  noctalia-greeter package 本身的 profile 注入由 channel service
  负责，这里只贡献本仓库定义的登录 session。"
  (simple-service 'noctalia-greeter-session-data
                  profile-service-type
                  (list %noctalia-greeter-session-data)))
