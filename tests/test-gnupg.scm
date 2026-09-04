;;; GnuPG app 测试（ephemeral GNUPGHOME + Home Shepherd 托管的
;;; gpg-agent supervised 模式；2026-08 从 one-shot + gpg 按需
;;; self-spawn 迁移为长驻托管）。
;;;
;;; 覆盖：
;;;   GN1  app 启用；GNUPGHOME 注入 session env（ephemeral
;;;        /run/user/<uid>/gnupg）；不注入 SSH agent 环境变量；
;;;   GN2  gnupg-session 是真正 one-shot（respawn? #f），只做
;;;        runtime/key 一次性初始化，不启动任何 daemon；
;;;   GN3  gpg-agent 是长驻 Shepherd service：systemd-style
;;;        constructor/destructor、--deprecated-supervised、
;;;        不启用 ssh support、socket 在 %user-runtime-dir/gnupg、
;;;        requirement gnupg-session、respawn? #f、lazy-start? #f、
;;;        显式传会话环境（environ + GNUPGHOME）；
;;;   GN4  源码边界：无 --enable-ssh-support、无 gpg-agent 二进制
;;;        的 --daemon 自 spawn 残留。
;;;   GN5  pinentry 权威配置：agent conf 是生成物（mixed-text-file
;;;        内嵌 pinentry-gtk-2 build-time store 路径作
;;;        pinentry-program）——本 key 带 passphrase，缺失时签名
;;;        失败 "No pinentry"（2026-09 VM 实测根因）。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg users user)     ; %primary-user、user-profile-uid
             (gnu home services)      ; home-environment-variables-service-type
             (gnu home services shepherd) ; home-shepherd-service-type、accessors
             (gnu services)           ; service-kind、service-value、
             ; service-type-extensions、service-extension-target
             (gnu services shepherd)  ; shepherd-service-*
             (ice-9 rdelim)           ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "gnupg")

(define (app-by-name name)
  (find (lambda (a) (eq? name (application-name a))) %applications))

(define %gnupg-app (app-by-name 'gnupg))

;; simple-service 会生成匿名 service-type（kind name = service 名），
;; 因此按 extension target 识别贡献类别（不按 service-kind eq）。
(define (app-contributions app target-type)
  (append-map service-value
              (filter (lambda (s)
                        (any (lambda (ext)
                               (eq? target-type
                                    (service-extension-target ext)))
                             (service-type-extensions (service-kind s))))
                      (application-home-services app))))

(define (shepherd-by-name app name)
  (find (lambda (s) (eq? name (shepherd-service-canonical-name s)))
        (app-contributions app home-shepherd-service-type)))

;; ── GN1：app 启用 + GNUPGHOME 环境 ────────────────────────
(test-assert "GN1: gnupg app enabled in registry"
             (and %gnupg-app (application? %gnupg-app)))

(test-assert "GN1: GNUPGHOME points at the ephemeral session runtime dir, \
and no SSH agent env var is injected (gpg-agent does not serve SSH)"
             (let* ((expected (string-append
                               "/run/user/"
                               (number->string (user-profile-uid
                                                %primary-user))
                               "/gnupg"))
                    (env-vars
                     (app-contributions
                      %gnupg-app home-environment-variables-service-type)))
               (and (= 1 (length env-vars))
                    (string=? "GNUPGHOME" (caar env-vars))
                    (string=? expected (cdar env-vars)))))

;; ── GN2：gnupg-session 一次性初始化（非 daemon owner）──────
(define %gnupg-session-svc
  (shepherd-by-name %gnupg-app 'gnupg-session))

(test-assert "GN2: gnupg-session is a true one-shot with respawn disabled"
             (let ((svc %gnupg-session-svc))
               (and svc
                    (shepherd-service-one-shot? svc)
                    (not (shepherd-service-respawn? svc))
                    (null? (shepherd-service-requirement svc)))))

(test-assert "GN2: gnupg-session wiring is forkexec + kill destructor, \
and does NOT start gpg-agent (daemon owned by the gpg-agent service)"
             (let ((start (object->string
                           (shepherd-service-start %gnupg-session-svc)))
                   (stop (object->string
                          (shepherd-service-stop %gnupg-session-svc))))
               (and (string-contains start "make-forkexec-constructor")
                    (string-contains stop "make-kill-destructor")
                    ;; wrapper 只用 /bin/gpg 导入 key，绝不拉起 agent
                    ;; （gpg-agent.conf 拷贝文件名不算启动）
                    (not (string-contains start "/bin/gpg-agent")))))

;; ── GN3：gpg-agent 长驻 supervised 托管 ───────────────────
(define %gnupg-gpg-agent-svc
  (shepherd-by-name %gnupg-app 'gpg-agent))

(test-assert "GN3: gpg-agent service exists, long-running, no respawn, \
after gnupg-session"
             (let ((svc %gnupg-gpg-agent-svc))
               (and svc
                    (not (shepherd-service-one-shot? svc))
                    (not (shepherd-service-respawn? svc))
                    (equal? '(gnupg-session)
                            (shepherd-service-requirement svc)))))

(test-assert "GN3: gpg-agent uses systemd-style constructor/destructor \
with --deprecated-supervised (pinned gnupg 2.5.20), eager start, \
session environment"
             (let ((start (object->string
                           (shepherd-service-start %gnupg-gpg-agent-svc)))
                   (stop (object->string
                          (shepherd-service-stop %gnupg-gpg-agent-svc))))
               (and (string-contains start "make-systemd-constructor")
                    (string-contains start "gpg-agent")
                    (string-contains start "--deprecated-supervised")
                    (string-contains start "#:lazy-start? #f")
                    (string-contains start "environ")
                    (string-contains start "GNUPGHOME")
                    (string-contains stop "make-systemd-destructor"))))

(test-assert "GN3: standard socket bound in %user-runtime-dir/gnupg \
with 0700 directory permissions (no ssh/browser/extra sockets)"
             (let ((s (object->string
                       (shepherd-service-start %gnupg-gpg-agent-svc))))
               ;; gexp 打印把 #o700 渲染为 448（writer 输出数值）。
               (and (string-contains s "%user-runtime-dir")
                    (string-contains s "/gnupg/S.gpg-agent")
                    (string-contains s "#:socket-directory-permissions 448")
                    (not (string-contains s "S.gpg-agent.ssh"))
                    (not (string-contains s "S.gpg-agent.browser"))
                    (not (string-contains s "S.gpg-agent.extra")))))

;; ── GN4：源码边界（无 SSH agent 语义、无 --daemon 自 spawn）─
(test-assert "GN4: no --enable-ssh-support anywhere in the app"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/gnupg/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "--enable-ssh-support"))))

(test-assert "GN4: no gpg-agent --daemon self-spawn invocation remains"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/gnupg/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "gpg-agent \""))))

;; ── GN5：pinentry 权威配置（2026-09 签名失败根因修复）───────
;; 本 key 带 passphrase：agent conf 必须携带 pinentry-program（缺失
;; 时 agent 报 "No pinentry"，所有签名失败）；conf 必须是生成物——
;; 静态文件无法携带版本相关的 store 路径（mixed-text-file 在
;; build-time 解析 pinentry 级联 wrapper 的路径）。
(test-assert "GN5: agent conf is generated (mixed-text-file) with a \
pinentry-program resolved from the cascade wrapper at build time"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/gnupg/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "pinentry-program")
                    (string-contains s "pinentry-cascade-wrapper")
                    (string-contains s "mixed-text-file")
                    (not (string-contains s "local-file \"gpg-agent.conf\"")))))

;; ── GN6：pinentry 级联（2026-09，主机 Arch wrapper 同设计）────
;; 图形环境（DISPLAY / WAYLAND_DISPLAY，agent 经 OPTION display /
;; putenv 转发）→ pinentry-gnome3（GTK3 现代风）；无图形 → gtk-2
;; （FALLBACK_CURSES 退终端）。纯 exec 语义、零探测。
(test-assert "GN6: cascade wrapper execs gnome3 on display, gtk-2 otherwise"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/gnupg/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "pinentry-gnome3")
                    (string-contains s "pinentry-gtk-2")
                    (string-contains s "WAYLAND_DISPLAY")
                    (string-contains s "execl"))))

(test-end "gnupg")
