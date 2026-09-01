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

(test-end "gnupg")
