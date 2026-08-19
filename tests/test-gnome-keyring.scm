;;; GNOME Keyring / Secret Service 测试（Phase B，
;;; docs/architecture/desktop-authentication.md）。
;;;
;;; 覆盖（任务 B15 static list）：
;;;   GK1  app 启用（registry）+ 官方 service 被使用、无 custom
;;;        daemon implementation；
;;;   GK2  PAM mapping 只覆盖本系统实际使用的 service（greetd/login/
;;;        passwd；无 gdm-password 残留）；
;;;   GK3  PAM lowering：greetd/login 的 auth+session 真实包含
;;;        pam_gnome_keyring（session 带 auto_start）、passwd 的
;;;        password 段包含同步模块、sshd 不受影响；
;;;   GK4  persistence 恰好一条：keyrings vault → data-app backing；
;;;        无整体 .local/share、无 /run/user、无 machine-state；
;;;   GK5  daemon 无双启动：niri/Home/shell 都不启动 daemon，模块内
;;;        无 gnome-keyring-daemon 手动 exec；
;;;   GK6  polkit authority 恰好一个（与 Phase A 同源断言）。

(use-modules (guixcfg hosts vm)
             (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg system application-persistence) ; rule accessors（GK4）
             (gnu services)
             (gnu services desktop) ; gnome-keyring-service-type
             (gnu services shepherd) ; shepherd-service-*（GK7 initializer）
             (gnu system)
             (gnu system file-systems) ; file-system-device/mount-point（GK4）
             (gnu system pam)       ; pam-service-name、pam-service-auth/session/password
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
(define gnome-keyring-pam-services
  (module-ref (resolve-module '(gnu services desktop))
              'gnome-keyring-pam-services))
(define pam-configuration-services
  (module-ref (resolve-module '(gnu system pam)) 'pam-configuration-services))
(define pam-configuration-transformers
  (module-ref (resolve-module '(gnu system pam)) 'pam-configuration-transformers))

(define (app-by-name name)
  (find (lambda (a) (eq? name (application-name a))) %applications))

(define %gnome-keyring-app (app-by-name 'gnome-keyring))

;; ── GK1：official service、无 custom daemon ────────────────
(test-assert "GK1: gnome-keyring app enabled in registry"
             (and %gnome-keyring-app (application? %gnome-keyring-app)))

(test-assert "GK1: official gnome-keyring-service-type used (exactly one)"
             (let ((svcs (application-system-services %gnome-keyring-app)))
               (and (= 1 (length svcs))
                    (eq? gnome-keyring-service-type
                         (service-kind (car svcs))))))

(test-assert "GK1: app definition contains no custom service type"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/gnome-keyring/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "define-service-type"))))

;; ── GK2：PAM mapping 精确覆盖 greetd/login/passwd ─────────
(test-assert "GK2: PAM mapping covers exactly greetd/login/passwd (no gdm-password)"
             (let ((mapping (gnome-keyring-pam-services
                             (service-value
                              (car (application-system-services
                                    %gnome-keyring-app))))))
               ;; alist key 是字符串（pinned transformer 用
               ;; pam-service-name 的字符串匹配）。
               (and (equal? '(("greetd" . login) ("login" . login)
                              ("passwd" . passwd))
                            mapping)
                    (not (assoc "gdm-password" mapping)))))

;; ── GK3：PAM lowering（与 /etc/pam.d 生成相同的折叠结果）───
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

(define (pam-keyring-entry? entry auto-start?)
  "ENTRY 是否是 pam_gnome_keyring.so（可选参数 AUTO-START? 时带
auto_start）。"
  (let ((m (object->string (pam-entry-module entry))))
    (and (string-contains m "pam_gnome_keyring.so")
         (equal? (if auto-start? '("auto_start") '())
                 (pam-entry-arguments entry)))))

(test-assert "GK3: greetd PAM auth captures the login password"
             (any (lambda (e) (pam-keyring-entry? e #f))
                  (pam-service-auth (final-pam-service "greetd"))))

(test-assert "GK3: greetd PAM session unlocks keyring and starts daemon"
             (any (lambda (e) (pam-keyring-entry? e #t))
                  (pam-service-session (final-pam-service "greetd"))))

(test-assert "GK3: console login PAM service unlocks keyring too"
             (let ((login (final-pam-service "login")))
               (and (any (lambda (e) (pam-keyring-entry? e #f))
                         (pam-service-auth login))
                    (any (lambda (e) (pam-keyring-entry? e #t))
                         (pam-service-session login)))))

(test-assert "GK3: passwd PAM service syncs keyring password"
             (any (lambda (e) (pam-keyring-entry? e #f))
                  (pam-service-password (final-pam-service "passwd"))))

(test-assert "GK3: sshd PAM service is NOT touched by the keyring"
             (let ((sshd (final-pam-service "sshd")))
               (and (not (any (lambda (e) (pam-keyring-entry? e #f))
                              (pam-service-auth sshd)))
                    (not (any (lambda (e) (pam-keyring-entry? e #t))
                              (pam-service-session sshd))))))

(test-assert "GK3: greeter PAM service (greetd-greeter) exists WITHOUT keyring
(greetd server.rs falls back to 'greetd' when /etc/pam.d/greetd-greeter
is missing - which would run pam_gnome_keyring in every greeter session
and spawn a --login stub per greeter start; regression: SSH-only round
showed exactly such a stray daemon)"
             (let ((greeter (final-pam-service "greetd-greeter")))
               (and greeter
                    (not (any (lambda (e) (pam-keyring-entry? e #f))
                              (pam-service-auth greeter)))
                    (not (any (lambda (e) (pam-keyring-entry? e #t))
                              (pam-service-session greeter)))
                    ;; 与 greetd 同一 unix-pam-service 基底（会话可用）
                    (pair? (pam-service-session greeter)))))

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

;; ── GK5：daemon 无双启动 ──────────────────────────────────
(test-assert "GK5: niri config starts the --start initializer exactly once"
             (let ((s (call-with-input-file "modules/guixcfg/apps/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (= 1 (length (filter (lambda (line)
                                      (string-contains line
                                                       "gnome-keyring-daemon"))
                                    (string-split s #\newline))))))

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

(test-assert "GK5: no gnome-keyring-daemon invocation in modules
(the Phase 2 initializer lives in niri config, not scheme code)"
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (find-files "modules/guixcfg" "\\.scm$"))
                       "\n")))
               ;; 只数 invocation 形态（带引号的 bin 路径）；注释里的
               ;; 裸名说明文档不算。
               (not (string-contains s "\"/bin/gnome-keyring-daemon\""))))

(test-assert "GK5: PAM auto_start is the single logical unlock owner
(no module passes the auto_start argument itself)"
             (let ((s (string-join
                       (map (lambda (f)
                              (call-with-input-file f
                                                    (lambda (p) (read-string p))))
                            (find-files "modules/guixcfg" "\\.scm$"))
                       "\n")))
               ;; auto_start 只允许由 official gnome-keyring service 生成；
               ;; 仓库模块里带引号的 "auto_start" 参数形态必须不存在
               ;; （注释里裸写 auto_start 说明文档不算）。
               (not (string-contains s "\"auto_start\""))))

;; ── GK7：Phase 2 由 niri 启动（--start 语义，单一 owner）──
;; 上游 lifecycle（pinned gnome-keyring-48.0，gkd-main.c）：
;;   PAM --login stub（解锁 login keyring，不完成初始化，120 秒
;;   超时）→ session --start 接管 stub、完成初始化、自身退出。
;; 本仓库的 Phase 2 owner = niri spawn-at-startup（architectural
;; compromise，desktop-authentication.md §2.2）。
(test-assert "GK7: niri spawn uses the exact --start --components=secrets"
             (let ((s (call-with-input-file "modules/guixcfg/apps/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (string-contains s
                                "spawn-at-startup \"gnome-keyring-daemon\" \"--start\" \"--components=secrets\"")))

(test-assert "GK7: the initializer is the only gnome-keyring spawn in niri"
             (let ((s (call-with-input-file "modules/guixcfg/apps/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (= 1 (length (filter (lambda (line)
                                      (string-contains line "spawn-at-startup"))
                                    (filter (lambda (line)
                                              (string-contains line
                                                               "gnome-keyring-daemon"))
                                            (string-split s #\newline)))))))

(test-assert "GK7: --start hook semantics (no --replace/--login/--daemonize/
--foreground in the spawn)"
             (let* ((s (call-with-input-file "modules/guixcfg/apps/niri/config.kdl"
                                            (lambda (p) (read-string p))))
                    ;; 只检查 spawn 行本身（config 注释会提到 --login 等
                    ;; lifecycle 词汇）。
                    (spawn-line
                     (find (lambda (line)
                             (string-contains line "gnome-keyring-daemon"))
                           (string-split s #\newline))))
               (and spawn-line
                    (not (string-contains spawn-line "--replace"))
                    (not (string-contains spawn-line "--login"))
                    (not (string-contains spawn-line "--daemonize"))
                    (not (string-contains spawn-line "--foreground")))))

(test-assert "GK7: gnome-keyring app has no daemon-starting home services
(PAM + niri are the only owners)"
             (null? (application-home-services %gnome-keyring-app)))

;; ── GK6：polkit authority 恰好一个（与 Phase A 同源）──────
(test-assert "GK6: exactly one polkit authority in %os"
             (= 1 (length (filter (lambda (svc)
                                    (eq? 'polkit
                                         (service-type-name (service-kind svc))))
                                  (operating-system-services %os)))))

(test-end "gnome-keyring")
