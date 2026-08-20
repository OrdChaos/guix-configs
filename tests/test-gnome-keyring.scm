;;; GNOME Keyring / Secret Service 测试（repository-owned master
;;; credential model，docs/architecture/desktop-authentication.md）。
;;;
;;; 覆盖：
;;;   GK1  app 启用；无 system-services（PAM 完全退出）；无 custom
;;;        service type；
;;;   GK2  /etc/pam.d/greetd/login/passwd 均无 pam_gnome_keyring
;;;        （login authentication 与 keyring unlocking 分离）；
;;;   GK3  greetd-greeter 专用 PAM 已删除（其存在理由已消失）；
;;;   GK4  persistence 恰好一条：keyrings vault；无整体 .local/share、
;;;        无 /run/user、无 machine-state；
;;;   GK5  daemon 单一 owner：niri 无 keyring spawn、modules 无
;;;        --login/--start、唯一 invocation = 会话 wrapper；
;;;   GK7  会话服务契约：Home Shepherd、requirement dbus、one-shot、
;;;        wrapper 用 --foreground --unlock --components=secrets、
;;;        密码不出现于 argv（无密码字面量参数）；
;;;   GK8  master credential secret 声明：恰好一条、scope user、
;;;        domain ordinary（不阻塞登录）、target/mode/owner 正确、
;;;        source 是加密 master.age；
;;;   GK6  polkit authority 恰好一个。

(use-modules (guixcfg hosts vm)
             (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg system application-persistence) ; rule accessors（GK4）
             (guixcfg security secrets) ; secret-decl accessors、runtime-secret-target（GK8）
             (guixcfg users user)     ; %primary-user（GK8）
             (gnu services)
             (gnu services shepherd) ; shepherd-service-*（GK7）
             (gnu system)
             (gnu system file-systems) ; file-system-device/mount-point（GK4）
             (gnu system pam)       ; pam-service-name、pam-service-auth/session/password
             (guix gexp)            ; gexp?、local-file（GK8 source）
             (guix build utils)     ; find-files（GK5 扫描）
             (ice-9 rdelim)         ; read-string
             (ice-9 ftw)            ; scandir
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "gnome-keyring")

;; 未导出 accessor 经顶层 define 绑定（编译环境内联 module-ref 应用
;; 会拿到 syntax-transformer——实测；与 test-desktop PK 同模式）。
(define pam-configuration-services
  (module-ref (resolve-module '(gnu system pam)) 'pam-configuration-services))
(define pam-configuration-transformers
  (module-ref (resolve-module '(gnu system pam)) 'pam-configuration-transformers))

(define (app-by-name name)
  (find (lambda (a) (eq? name (application-name a))) %applications))

(define %gnome-keyring-app (app-by-name 'gnome-keyring))

;; ── GK1：official service 退出 PAM、无 custom 实现 ────────
(test-assert "GK1: gnome-keyring app enabled in registry"
             (and %gnome-keyring-app (application? %gnome-keyring-app)))

(test-assert "GK1: app declares NO system services (PAM fully out)"
             (null? (application-system-services %gnome-keyring-app)))

(test-assert "GK1: app definition contains no custom service type"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/gnome-keyring/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "define-service-type"))))

;; ── GK2：PAM 完全无 keyring ───────────────────────────────
(define %pam-cfg
  (service-value
   (fold-services (operating-system-services %os)
                  #:target-type pam-root-service-type)))

(define (final-pam-service name)
  "应用全部 transformers 后的 NAME PAM service（即 /etc/pam.d/NAME
的实际内容）。"
  (let ((svc (find (lambda (s) (string=? name (pam-service-name s)))
                   (pam-configuration-services %pam-cfg))))
    (and svc
         ((apply compose identity (pam-configuration-transformers %pam-cfg))
          svc))))

(define (pam-keyring-entry? entry)
  "ENTRY 是否引用 pam_gnome_keyring.so。"
  (let ((m (object->string (pam-entry-module entry))))
    (string-contains m "pam_gnome_keyring.so")))

(test-assert "GK2: greetd PAM has NO pam_gnome_keyring in auth/session"
             (let ((greetd (final-pam-service "greetd")))
               (and greetd
                    (not (any pam-keyring-entry?
                              (pam-service-auth greetd)))
                    (not (any pam-keyring-entry?
                              (pam-service-session greetd))))))

(test-assert "GK2: login (console) PAM has NO pam_gnome_keyring"
             (let ((login (final-pam-service "login")))
               (and login
                    (not (any pam-keyring-entry?
                              (pam-service-auth login)))
                    (not (any pam-keyring-entry?
                              (pam-service-session login))))))

(test-assert "GK2: passwd PAM has NO pam_gnome_keyring (no password sync)"
             (let ((passwd (final-pam-service "passwd")))
               (and passwd
                    (not (any pam-keyring-entry?
                              (pam-service-password passwd))))))

(test-assert "GK2: no gnome-keyring-service-type in the OS graph"
             (not (any (lambda (svc)
                         (eq? 'gnome-keyring
                              (service-type-name (service-kind svc))))
                       (operating-system-services %os))))

;; ── GK3：greetd-greeter 专用 PAM 已删除 ───────────────────
(test-assert "GK3: greetd-greeter PAM service removed (reason gone)"
             (not (find (lambda (s)
                          (string=? "greetd-greeter" (pam-service-name s)))
                        (pam-configuration-services %pam-cfg))))

;; ── GK4：persistence 边界 ─────────────────────────────────
(test-assert "GK4: persistence is exactly the keyrings vault rule"
             (let ((rules (application-persistence %gnome-keyring-app)))
               (and (= 1 (length rules))
                    (let ((r (car rules)))
                      (and (string=? "gnome-keyring/keyrings"
                                     (application-persistence-rule-backing r))
                           (string=? ".local/share/keyrings"
                                     (application-persistence-rule-consumer r))
                           (eq? 'bind-directory
                                (application-persistence-rule-exposure r))
                           (eq? 'application-owned
                                (application-persistence-rule-lifecycle r)))))))

(test-assert "GK4: no broad .local/share persistence across all apps"
             (let ((consumers
                    (append-map (lambda (r)
                                  (list (application-persistence-rule-consumer r)))
                                (applications-persistence %applications))))
               (every (lambda (c)
                        (or (not (string-prefix? ".local/share/" c))
                            (string=? ".local/share/keyrings" c)))
                      consumers)))

(test-assert "GK4: no /run/user persistence anywhere"
             (every (lambda (r)
                      (and (not (string-prefix? "/" (application-persistence-rule-consumer r)))
                           (not (string-prefix? "/" (application-persistence-rule-backing r)))))
                    (applications-persistence %applications)))

(test-assert "GK4: keyrings bind mount declared in %os"
             (any (lambda (fs)
                    (and (string=? "/home/user/.local/share/keyrings"
                                   (file-system-mount-point fs))
                         (string=? "/persist/data-app/gnome-keyring/keyrings"
                                   (file-system-device fs))))
                  (operating-system-file-systems %os)))

(test-assert "GK4: no machine-state rule wired in %os"
             (not (any (lambda (svc)
                         (eq? 'machine-state-persistence
                              (service-type-name (service-kind svc))))
                       (operating-system-services %os))))

;; ── GK5：daemon 单一 owner、无旧 lifecycle ────────────────
(test-assert "GK5: niri config has no gnome-keyring spawn"
             (let ((s (call-with-input-file "modules/guixcfg/apps/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "gnome-keyring"))))

(test-assert "GK5: no --login / --start anywhere in modules
(PAM --login stub and niri/Home --start glue fully removed)"
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (find-files "modules/guixcfg" "\\.scm$"))
                       "\n")))
               (and (not (string-contains s "\"--login\""))
                    (not (string-contains s "\"--start\"")))))

(test-assert "GK5: no OTHER app definition starts the daemon"
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (filter (lambda (f)
                                      (not (string-contains f "gnome-keyring")))
                                    (find-files "modules/guixcfg/apps"
                                                "definition\\.scm$")))
                       "\n")))
               (not (string-contains s "gnome-keyring-daemon"))))

(test-assert "GK5: exactly one gnome-keyring-daemon invocation in modules
(the session wrapper)"
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (find-files "modules/guixcfg" "\\.scm$"))
                       "\n")))
               ;; 只数 invocation 形态（带引号的 bin 路径）；注释里的
               ;; 裸名说明文档不算。
               (= 1 (length (filter (lambda (m)
                                      (string-contains m
                                                       "\"/bin/gnome-keyring-daemon\""))
                                    (string-split s #\newline))))))

;; ── GK7：会话服务契约（单一 lifecycle owner）──────────────
(define %gk-session-svc
  (car (service-value
        (car (application-home-services %gnome-keyring-app)))))

(test-assert "GK7: session service is Home Shepherd, after D-Bus, one-shot"
             (let ((svc %gk-session-svc))
               (and (eq? 'gnome-keyring-session
                         (car (shepherd-service-provision svc)))
                    (equal? '(dbus) (shepherd-service-requirement svc))
                    (shepherd-service-one-shot? svc))))

(test-assert "GK7: wrapper invokes --foreground --unlock --components=secrets
(pinned Model 1; password via stdin, never argv)"
             (let ((s (object->string (shepherd-service-start %gk-session-svc))))
               (and (string-contains s "gnome-keyring-daemon")
                    (string-contains s "--foreground")
                    (string-contains s "--unlock")
                    (string-contains s "--components=secrets")
                    (not (string-contains s "--login"))
                    (not (string-contains s "--start"))
                    (not (string-contains s "--daemonize")))))

(test-assert "GK7: secret is delivered via stdin redirection from the /run
target (no password in argv/env of the wrapper)"
             (let* ((target (runtime-secret-target
                             (car (application-secrets %gnome-keyring-app))
                             (user-profile-name %primary-user)))
                    (s (object->string (shepherd-service-start %gk-session-svc))))
               (string-contains s target)))

(test-assert "GK7: service is session infrastructure (home shepherd),
not system/boot/niri"
             (and (pair? (application-home-services %gnome-keyring-app))
                  (null? (application-system-services %gnome-keyring-app))))

;; ── GK8：master credential secret 声明 ────────────────────
(test-assert "GK8: app owns exactly one secret declaration"
             (let ((secrets (application-secrets %gnome-keyring-app)))
               (and (= 1 (length secrets))
                    (eq? 'gnome-keyring-master
                         (secret-decl-name (car secrets))))))

(test-assert "GK8: secret is user-scoped and ORDINARY (never blocks login)"
             (let ((d (car (application-secrets %gnome-keyring-app))))
               (and (eq? 'user (secret-decl-scope d))
                    (eq? 'ordinary (secret-decl-domain d)))))

(test-assert "GK8: source is the encrypted master.age (no plaintext source)"
             (let* ((d (car (application-secrets %gnome-keyring-app)))
                    (src (secret-decl-source d)))
               (and (local-file? src)
                    (string-suffix? "master.age" (local-file-file src)))))

(test-assert "GK8: runtime target is the canonical ordinary user path
with strict permissions"
             (let* ((d (car (application-secrets %gnome-keyring-app)))
                    (user (user-profile-name %primary-user))
                    (target (runtime-secret-target d user)))
               (and (string=? (string-append
                               "/run/guixcfg-secrets-ordinary/users/"
                               user "/gnome-keyring-master")
                              target)
                    (string=? user (secret-decl-owner-user d))
                    (eq? #o400 (secret-decl-mode d)))))

;; ── GK6：polkit authority 恰好一个（与 Phase A 同源）──────
(test-assert "GK6: exactly one polkit authority in %os"
             (= 1 (length (filter (lambda (svc)
                                    (eq? 'polkit
                                         (service-type-name (service-kind svc))))
                                  (operating-system-services %os)))))

(test-end "gnome-keyring")
