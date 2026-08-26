;;; M2 Wayland desktop 单元测试（D1-D7 可单元化部分 + NV1-NV8）。
;;;
;;; 覆盖：
;;;   D1 greetd 配置生成（tty1 terminal）
;;;   D2 greetd gated by interactive-session-ready（shepherd requirement）
;;;   D3 tty2 mingetty fallback 保留（且同样 gated）
;;;   D4 无 autologin（initial-session-user #f）+ 空密码禁用
;;;   D5 elogind 仍是唯一 session authority（服务存在）
;;;   D6/D7 /run/user 生命周期属 runtime（VM acceptance，见报告）
;;;   H1-H5 HOME provenance 契约（greetd upstream 从 passwd entry
;;;       设置 HOME；pam_env 无 HOME 规则；官方 wrapper 只设 XDG_*）
;;;   NV1 NVIDIA adapter 默认 disabled/identity
;;;   NV2 VM OS 无 proprietary NVIDIA 包
;;;   NV3 VM kernel args 无 nouveau blacklist
;;;   NV4 common desktop 模块不引用 NVIDIA/vendor 符号（无 layer leak）
;;;   NV5 NVIDIA adapter 拥有并记录未来 ownership
;;;   NV6 kernel 仍由 kernel-platform 拥有
;;;   NV7 未来 package-transform 默认 identity
;;;   NV8 无全局 PRIME/DRM 环境变量（niri config + desktop 源码）
;;;
;;; 不构建任何 NVIDIA 内容、不访问公网（niri validate 等属 VM
;;; runtime acceptance）。

(use-modules (guixcfg hosts vm)
             (guixcfg system desktop)
             (guixcfg system common) ; %common-services（PK1）
             (guixcfg system graphics nvidia)
             (guixcfg system kernel-platform)
             (guixcfg users user)    ; %primary-user（mount point 推导）
             (gnu services)
             (gnu services base)   ; greetd-service-type、mingetty-service-type
             (gnu services desktop) ; elogind-service-type
             (gnu services shepherd) ; shepherd-root-service-type
             (gnu services dbus)    ; polkit-service-type（PK：polkit authority）
             (gnu system)          ; operating-system-*
             (gnu system file-systems)  ; file-system-device、file-system-mount-point
             (gnu system pam)      ; unix-pam-service、pam-entry-module/arguments
             (guix packages)       ; package-name
             (nongnu packages linux) ; linux（nonguix）
             (guix channels)          ; channel-name、channel-commit（解析 lock）
             (ice-9 rdelim)
             (ice-9 ftw)               ; scandir
             (guix build utils)       ; find-files（PK2 rules.d 扫描）
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (os-service service-type)
  "从 %os 的 services 里按 SERVICE-TYPE 折叠出配置。"
  (fold-services (operating-system-services %os)
                 #:target-type service-type))

(define (all-shepherd-services)
  "%os 的 shepherd root 服务列表。"
  (service-value
   (os-service shepherd-root-service-type)))

;; greetd 记录访问器未从 (gnu services base) 导出，经模块内绑定访问。
(define greetd-terminals (@ (gnu services base) greetd-terminals))
(define greetd-allow-empty-passwords?
  (@ (gnu services base) greetd-allow-empty-passwords?))
(define greetd-terminal-vt
  (@ (gnu services base) greetd-terminal-vt))
(define greetd-terminal-configuration-initial-session-user
  (@ (gnu services base) greetd-initial-session-user))
(define greetd-default-session-command
  (@ (gnu services base) greetd-default-session-command))
(define greetd-default-session-user
  (@ (gnu services base) greetd-default-session-user))
(define greetd-agreety-session?
  (@ (gnu services base) greetd-agreety-session?))
(define greetd-agreety-session-command
  (@ (gnu services base) greetd-agreety-session-command))
(define greetd-user-session?
  (@ (gnu services base) greetd-user-session?))
(define greetd-user-session-command-args
  (@ (gnu services base) greetd-user-session-command-args))
(define greetd-user-session-xdg-session-type
  (@ (gnu services base) greetd-user-session-xdg-session-type))
(define greetd-user-session-xdg-env?
  (@ (gnu services base) greetd-user-session-xdg-env?))

(define %guix-store-dir
  ;; store 中 pinned Guix channel 源（channel 内容是内容寻址的：
  ;; channels.lock.scm 锁定的 commit 对应唯一 store 路径）。注意
  ;; store 里还有同前缀的 -modules 目录（profile 用），必须选
  ;; 真正含 gnu/services/base.scm 的 channel checkout。
  (let* ((lock (eval (call-with-input-file "channels.lock.scm" read)
                     (current-module)))
         (commit (channel-commit
                  (find (lambda (ch) (eq? (channel-name ch) 'guix))
                        lock)))
         (short (substring commit 0 7))
         (hits (scandir "/gnu/store"
                        (lambda (name)
                          (string-contains name
                                           (string-append "-guix-" short)))))
         (candidates
          (filter (lambda (d)
                    (file-exists?
                     (string-append "/gnu/store/" d
                                    "/gnu/services/base.scm")))
                  hits)))
    (if (pair? candidates)
      (string-append "/gnu/store/" (car candidates))
      (error "guix channel source not in store; run time-machine first"
             commit))))

(define (os-services-of-type type)
  "扫描 %os 的 services 列表（不 fold——mingetty 等多实例类型）。"
  (filter (lambda (svc) (eq? (service-kind svc) type))
          (operating-system-services %os)))

(test-begin "desktop")

;; ── D1：greetd 配置生成 ────────────────────────────────────
(test-assert "D1: greetd service present with a tty1 terminal"
             (let ((cfg (service-value (os-service greetd-service-type))))
               (and (pair? (greetd-terminals cfg))
                    (any (lambda (tc)
                           (string=? "1" (greetd-terminal-vt tc)))
                         (greetd-terminals cfg)))))

;; ── D2：greetd gated by interactive-session-ready ──────────
(test-assert "D2: greetd tty1 requires interactive-session-ready"
             (let* ((cfg (service-value (os-service greetd-service-type)))
                    (tc (find (lambda (tc)
                                (string=? "1" (greetd-terminal-vt tc)))
                              (greetd-terminals cfg))))
               (member 'interactive-session-ready
                       ((@ (gnu services base) greetd-extra-shepherd-requirement)
                        tc))))

;; ── D3：tty1 归 greetd，mingetty fallback 在 tty2+ 且 gated ──
(test-assert "D3: no mingetty on tty1 (greetd owns it)"
             (not (any (lambda (svc)
                         (string=? "tty1"
                                   (mingetty-configuration-tty
                                    (service-value svc))))
                       (os-services-of-type mingetty-service-type))))

(test-assert "D3: mingetty fallback present on tty2"
             (any (lambda (svc)
                    (string=? "tty2"
                              (mingetty-configuration-tty
                               (service-value svc))))
                  (os-services-of-type mingetty-service-type)))

(test-assert "D3: fallback mingetty gated by interactive-session-ready"
             (any (lambda (svc)
                    (member 'interactive-session-ready
                            (mingetty-configuration-shepherd-requirement
                             (service-value svc))))
                  (os-services-of-type mingetty-service-type)))

;; ── D4：无 autologin、空密码禁用 ───────────────────────────
(test-assert "D4: no autologin (initial-session-user unset)"
             (let ((cfg (service-value (os-service greetd-service-type))))
               (every (lambda (tc)
                        (not (greetd-terminal-configuration-initial-session-user
                              tc)))
                      (greetd-terminals cfg))))

(test-assert "D4: empty passwords disabled"
             (not (greetd-allow-empty-passwords?
                   (service-value (os-service greetd-service-type)))))

;; ── LG：last-good promote 时机（成功图形登录后）─────────────
;; pam-configuration 访问器未导出，经模块内绑定（同 GK 组
;; test-gnome-keyring 的模式）。
(define pam-configuration-services
  (module-ref (resolve-module '(gnu system pam)) 'pam-configuration-services))
(define pam-configuration-transformers
  (module-ref (resolve-module '(gnu system pam)) 'pam-configuration-transformers))

(define %pam-cfg
  (service-value (fold-services (operating-system-services %os)
                                #:target-type pam-root-service-type)))

(define (final-pam-service name)
  "应用全部 transformers 后的 NAME PAM service（/etc/pam.d/NAME
的实际内容）。"
  (let ((svc (find (lambda (s) (string=? name (pam-service-name s)))
                   (pam-configuration-services %pam-cfg))))
    (and svc
         ((apply compose identity (pam-configuration-transformers %pam-cfg))
          svc))))

(define (pam-exec-confirm-entry? entry)
  "ENTRY 是否是指向 ephemeral-root-confirm 的 pam_exec。"
  (and (string-contains (object->string (pam-entry-module entry))
                        "pam_exec.so")
       (any (lambda (arg)
              (string-contains (object->string arg)
                               "ephemeral-root-confirm"))
            (pam-entry-arguments entry))))

(test-assert "LG1: greetd PAM session runs confirm via pam_exec"
             (let ((greetd (final-pam-service "greetd")))
               (and greetd
                    (any pam-exec-confirm-entry?
                         (pam-service-session greetd)))))

(test-assert "LG1: login/sshd PAM have NO confirm hook"
             (every (lambda (name)
                      (let ((svc (final-pam-service name)))
                        (and svc
                             (not (any pam-exec-confirm-entry?
                                       (pam-service-session svc))))))
                    '("login" "sshd")))

(test-assert "LG2: no boot-time confirm shepherd service"
             (not (any (lambda (svc)
                         (member 'ephemeral-root-confirm
                                 (shepherd-service-provision svc)))
                       (shepherd-configuration-services
                        (all-shepherd-services)))))

(test-assert "LG2: cleanup anchored at persistent-state-ready (pre-login)"
             (any (lambda (svc)
                    (and (member 'ephemeral-root-cleanup
                                 (shepherd-service-provision svc))
                         (equal? '(persistent-state-ready)
                                 (shepherd-service-requirement svc))))
                  (shepherd-configuration-services
                   (all-shepherd-services))))

;; ── D5：elogind 仍是 session authority ─────────────────────
(test-assert "D5: elogind service present in %os"
             (let ((cfg (os-service elogind-service-type)))
               (and cfg #t)))

;; ── HOME provenance（exact pinned source audit）────────────
;; 契约（desktop.scm 头注释 + docs/architecture/graphics.md）：
;;   用户会话 HOME 由 greetd 0.10.3 从认证用户的 passwd entry 设置
;;   （src/session/worker.rs:162-216：getpwnam → putenv
;;   USER/LOGNAME/HOME/SHELL → getenvlist → execve(/bin/sh -c
;;   "exec <session>", envvec)——execve 整体替换环境，greeter 的
;;   HOME=/var/empty 不可能继承）；agreety 只经 IPC 发 cmd + env='()
;;   （agreety/src/main.rs:107-110）。
;;   这里固定我们配置侧可断言的部分（upstream 部分经 pinned source
;;   注释固定）：
;;   H1 default-session-command 必须是官方 agreety greeter 模式
;;      （greetd-agreety-session 包装 greetd-user-session）——
;;      Guix 手册 guix.texi "greetd-service-type"：default session =
;;      greeter，默认值 (greetd-agreety-session)。若被改成
;;      greetd-user-session 直接值，greetd 会把它当 greeter 以
;;      greeter 用户无认证运行（server.rs greet()→start_greeter，
;;      authenticate=false）——无登录提示符，HOME=/var/empty。
;;   H2 greeter 的 user-session = bash -l + wayland + xdg-env。
;;   H3 greetd PAM 栈里 pam_env.so 无参数（只 honor
;;      /etc/environment——本机为空；不能设置 HOME）。
;;   H4 default session 以 greeter 专用账号运行（用户会话的 HOME
;;      与 greeter 无关，worker.rs 从认证用户 passwd 重取）。
;;   H5 pinned Guix 官方 wrapper（make-greetd-xdg-user-session-
;;      command，base.scm:3715-3729）只 setenv XDG_SESSION_TYPE/
;;      XDG_RUNTIME_DIR（getpwuid），不 setenv HOME/USER/LOGNAME/
;;      SHELL（wrapper 会 getenv "USER" 读 greetd 设置的用户名来查
;;      passwd——只读不算 setenv）。

(define (tty1-terminal)
  "tty1 greetd terminal 配置记录。"
  (let ((cfg (service-value (os-service greetd-service-type))))
    (find (lambda (tc) (string=? "1" (greetd-terminal-vt tc)))
          (greetd-terminals cfg))))

(test-assert "H1: default-session-command is agreety greeter wrapping user-session"
             (let ((cmd (greetd-default-session-command (tty1-terminal))))
               (greetd-agreety-session? cmd)))

(test-assert "H2: greeter user-session is bash -l wayland with xdg-env"
             (let* ((cmd (greetd-default-session-command (tty1-terminal)))
                    (s (greetd-agreety-session-command cmd)))
               (and (greetd-agreety-session? cmd)
                    (greetd-user-session? s)
                    (equal? (greetd-user-session-command-args s) '("-l"))
                    (string=? "wayland"
                              (greetd-user-session-xdg-session-type s))
                    (greetd-user-session-xdg-env? s))))

(test-assert "H3: greetd PAM pam_env.so has no arguments (cannot set HOME)"
             (let* ((pam (unix-pam-service "greetd"
                                           #:login-uid? #t
                                           #:allow-empty-passwords? #f))
                    (env-entry (find (lambda (e)
                                       (string-contains
                                        (pam-entry-module e) "pam_env"))
                                     (pam-service-session pam))))
               (and env-entry
                    (null? (pam-entry-arguments env-entry)))))

(test-assert "H4: default session runs as the greeter-only user"
             (string=? "greeter" (greetd-default-session-user (tty1-terminal))))

(test-assert "H5: official xdg wrapper sets only XDG_* (no HOME/USER/LOGNAME/SHELL)"
             (let* ((s (call-with-input-file
                        (string-append %guix-store-dir "/gnu/services/base.scm")
                        (lambda (p) (read-string p))))
                    (start (string-contains
                            s "(define (make-greetd-xdg-user-session-command"))
                    (tail (substring s start))
                    (end (string-contains
                          tail
                          "(define-gexp-compiler (greetd-user-session-compiler"))
                    (body (substring tail 0 end)))
               (and body
                    (string-contains body "(setenv \"XDG_SESSION_TYPE\"")
                    (string-contains body "(setenv \"XDG_RUNTIME_DIR\"")
                    (not (string-contains body "(setenv \"HOME\""))
                    (not (string-contains body "(setenv \"USER\""))
                    (not (string-contains body "(setenv \"LOGNAME\""))
                    (not (string-contains body "(setenv \"SHELL\"")))))

;; ── D8：application persistence production wiring（mpv 第一个
;;     真实 rule：host assembly 消费 applications-persistence）──
(test-assert "D8: mpv state bind mount declared in %os"
             (any (lambda (fs)
                    (and (string=?
                          (string-append (user-profile-home-directory
                                          %primary-user)
                                         "/.local/state/mpv")
                          (file-system-mount-point fs))
                         (string=? "/persist/data-app/mpv/state"
                                   (file-system-device fs))))
                  (operating-system-file-systems %os)))

(test-assert "D8: application-persistence activation service present in %os"
             (any (lambda (svc)
                    (eq? 'application-persistence
                         (service-type-name (service-kind svc))))
                  (operating-system-services %os)))

;; ── D9：guix-daemon 本地构建 tmpdir 声明（common services；
;;     2026-08-25：/tmp 7.7GB tmpfs 装不下内核编译 ~11GB 中间产物，
;;     显式 TMPDIR=/var/tmp——pinned guix-configuration tmpdir 字段；
;;     注意 guix-tmpdir accessor 未被上游导出（base.scm #:export
;;     遗漏），经 module-ref 访问）──
(define (os-guix-config)
  "折叠 %os 的 guix-service-type 配置。"
  (service-value
   (fold-services (operating-system-services %os)
                  #:target-type guix-service-type)))

(define %guix-tmpdir
  (module-ref (resolve-module '(gnu services base)) 'guix-tmpdir))

(test-assert "D9: guix-daemon tmpdir is declared as /var/tmp"
             (string=? "/var/tmp" (%guix-tmpdir (os-guix-config))))

(test-assert "D9: guix-service-type explicitly declared in %common-services"
             (any (lambda (svc)
                    (eq? (service-kind svc) guix-service-type))
                  %common-services))

;; ── NV1：NVIDIA adapter 默认 disabled/identity ─────────────
(test-assert "NV1: NVIDIA adapter disabled by default"
             (not %nvidia-adapter-enabled?))

(test-assert "NV1: adapter contributions are empty"
             (and (null? nvidia-kernel-arguments)
                  (null? nvidia-system-packages)
                  (null? nvidia-system-services)
                  (null? nvidia-user-packages)))

;; ── NV2：VM OS 无 proprietary NVIDIA 包 ────────────────────
(test-assert "NV2: %os packages contain no nvidia stack"
             (every (lambda (p)
                      (not (string-contains (package-name p) "nvidia")))
                    (operating-system-packages %os)))

;; ── NV3：VM kernel args 无 nouveau blacklist ───────────────
(test-assert "NV3: VM configuration adds no nouveau blacklist"
             ;; kernel-arguments 是 gexp（lower 前不可直接扫描）；从声明
             ;; 层断言：host/desktop/adapter 都没有引入 nouveau（Guix
             ;; 默认 args 仅 modprobe.blacklist=usbmouse,usbkbd + quiet）。
             (let ((s (call-with-input-file "modules/guixcfg/hosts/vm.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "nouveau"))))

;; ── NV4：desktop/niri 模块无 vendor layer leak ─────────────
(define %vendor-words
  ;; 注意："xe" 作为独立 token 才相关（i915/xe），不单独列出——
  ;; 会误匹配 execl 等子串；"i915" 已覆盖 Intel driver 路径。
  '("nvidia" "nouveau" "nvda" "virtio_gpu" "i915" "renderD"
             "/dev/dri" "card0" "card1"))

(define (text-contains-any? text words)
  (any (lambda (w) (string-contains text w)) words))

(test-assert "NV4: desktop.scm has no vendor-specific references"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s %vendor-words))))

(test-assert "NV4: niri common config has no DRM node / output name"
             ;; 拆分后 config.kdl 是 include-only 薄入口；机器事实
             ;; 只允许出现在 host 贡献的 host.kdl（laptop），
             ;; application-owned 的 common.kdl 必须无 vendor 泄漏。
             (let ((s (call-with-input-file "modules/guixcfg/apps/niri/common.kdl"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s
                                        (append %vendor-words
                                                '("Virtual-1" "eDP-1"
                                                              "DP-1" "HDMI-A-1"))))))

;; ── NV5：NVIDIA adapter 记录未来 ownership ─────────────────
(test-assert "NV5: nvidia adapter module documents its ownership"
             (let ((s (call-with-input-file
                       "modules/guixcfg/system/graphics/nvidia.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "nouveau blacklist")
                    (string-contains s "PRIME")
                    (string-contains s "Secure Boot module-signing")
                    (string-contains s "kernel-platform"))))

;; ── NV6：kernel 仍由 kernel-platform 拥有 ──────────────────
(test-assert "NV6: %os kernel is still %kernel (kernel-platform owns it)"
             (eq? (operating-system-kernel %os) %kernel))

;; ── NV7：package-transform 默认 identity ───────────────────
(test-assert "NV7: nvidia package transform defaults to identity"
             (eq? nvidia-package-transform identity))

;; ── NV8：无全局 PRIME/DRM 环境变量 ─────────────────────────
(test-assert "NV8: niri common config has no global PRIME/DRM env vars"
             (let ((s (call-with-input-file "modules/guixcfg/apps/niri/common.kdl"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s
                                        '("PRIME" "WLR_DRM_DEVICES"
                                                  "GBM_BACKEND" "WLR_RENDERER"
                                                  "WLR_BACKENDS")))))

(test-assert "NV8: desktop.scm sets no global vendor env vars"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s
                                        '("PRIME" "WLR_DRM_DEVICES"
                                                  "GBM_BACKEND" "__GLX_VENDOR")))))

;; ── PK：polkit system authority（Phase A；docs/architecture/
;; desktop-authentication.md）───────────────────────────────
;; polkitd 属于 system（经 system D-Bus activation 启动，无 shepherd
;; 服务）；elogind 的 service extension 已经隐式物化 polkit
;; （instantiate-missing-services），assembly 再显式声明 authority；
;; polkit-gnome 只是 graphical session agent（apps/polkit-gnome，
;; niri spawn-at-startup + ~/.local/bin wrapper）——不拥有 polkit。
(test-assert "PK1: exactly one polkit authority in %os"
             (= 1 (length (os-services-of-type polkit-service-type))))

(test-assert "PK1: polkit service is explicitly declared in common services"
             (let* ((common (map (compose service-type-name service-kind)
                                 %common-services)))
               (member 'polkit common)))

;; polkit 内部 accessor 未导出；经顶层 define 绑定（编译环境内联
;; module-ref 应用会拿到 syntax-transformer——实测）。
(define %polkit-configuration-actions
  (module-ref (resolve-module '(gnu services dbus))
              'polkit-configuration-actions))

(test-assert "PK2: polkit action/rules contributions come only from elogind
+ upstream wheel admin rule + NetworkManager (no custom rules)"
             (let* ((folded (fold-services (operating-system-services %os)
                                           #:target-type polkit-service-type))
                    (actions (%polkit-configuration-actions
                              (service-value folded))))
               ;; 3 = elogind + polkit-wheel + NetworkManager（NM 的
               ;; polkit actions——2026-08-25 VM 网络换 NetworkManager
               ;; 引入，Guix 官方 service 自带，非仓库 custom rules）。
               (= 3 (length actions))))

(test-assert "PK2: upstream polkit-wheel admin identity is used"
             (any (lambda (svc)
                    (eq? 'polkit-wheel (service-type-name (service-kind svc))))
                  (operating-system-services %os)))

;; polkit 内部 accessor 未导出；经顶层 define 绑定（编译环境内联
;; module-ref 应用会拿到 syntax-transformer——实测）。
(define %polkit-configuration-actions
  (module-ref (resolve-module '(gnu services dbus))
              'polkit-configuration-actions))

(test-assert "PK2: repo modules declare no custom /etc/polkit-1 rules"
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (find-files "modules/guixcfg" "\\.scm$"))
                       "\n")))
               (not (string-contains s "rules.d"))))

(test-assert "PK3: polkit-gnome starts once, from the graphical session only"
             ;; 拆分后 spawn 位于 common.kdl——扫描全部 niri kdl
             ;; 文件（config.kdl 入口 / common.kdl 通用 / host.kdl
             ;; host 贡献）确保恰好一次。
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (find-files "modules/guixcfg/apps/niri" "\\.kdl$"))
                       "\n")))
               (= 1 (length (filter (lambda (line)
                                      (string-contains line
                                                       "spawn-at-startup \"polkit-gnome-authentication-agent-1\""))
                                    (string-split s #\newline))))))

(test-assert "PK3: no boot shepherd service provisions the polkit agent"
             ;; 不用文本扫描：guix-home-user 服务里嵌着整个
             ;; <home-environment> record（包名/wrapper 文件名都会
             ;; 出现）；正确断言是 provision 名——agent 不是系统
             ;; daemon，boot shepherd 图里没有任何 polkit-gnome 服务。
             (let* ((folded (fold-services (operating-system-services %os)
                                           #:target-type shepherd-root-service-type))
                    (cfg (service-value folded)))
               (not (any (lambda (svc)
                           (any (lambda (p)
                                  (string-contains (symbol->string p)
                                                   "polkit-gnome"))
                                (shepherd-service-provision svc)))
                         (shepherd-configuration-services cfg)))))

(test-end "desktop")
