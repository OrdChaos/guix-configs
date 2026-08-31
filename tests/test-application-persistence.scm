;;; Application persistence generic engine 测试：synthetic rules 验证
;;; 机制本身（真实 production rule——mpv/gnome-keyring/google-chrome/
;;; noctalia/vscode——的接线由 test-desktop.scm D8 与各 app 测试覆盖）。
;;;
;;; 覆盖：backing/consumer 生成、bind file-system source/target、
;;; path validation（..、绝对路径、空、整目录 consumer 拒绝）、
;;; exposure 契约（bind-directory / bind-file 合法、未知拒绝）、
;;; bind-file 语义（create-mount-point? #f、backing/consumer
;;; regular-file 激活、与 bind-directory 共存、seeds 组合拒绝）、
;;; activation/ownership 可生成、seed-once seeds 字段/校验/接线、
;;; 无 data-nobackup mapping、无 copy/sync 实现。

(use-modules (guixcfg system application-persistence)
             (gnu services)
             (gnu system file-systems)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "application-persistence")

;; ── synthetic rule（测试专用；mechanism 验证）────────────────
(define rule
  (application-persistence-rule
   (name 'synthetic-test)
   (backing "synthetic-test/state")
   (consumer ".config/synthetic-test")
   (exposure 'bind-directory)
   (lifecycle 'application-owned)))

(define seeded-rule
  (application-persistence-rule
   (name 'seeded-test)
   (backing "seeded-test/state")
   (consumer ".local/state/seeded-test")
   (seeds `(("settings.toml"
             ,(plain-file "settings.toml" "[shell]\nsetup_wizard_enabled = false\n"))))))

(test-assert "rule record constructible"
             (application-persistence-rule? rule))
(test-equal "rule exposure default is bind-directory"
            'bind-directory
            (application-persistence-rule-exposure
             (application-persistence-rule
              (name 'x) (backing "x") (consumer ".config/x"))))
(test-equal "rule lifecycle default is application-owned"
            'application-owned
            (application-persistence-rule-lifecycle
             (application-persistence-rule
              (name 'x) (backing "x") (consumer ".config/x"))))
(test-assert "valid rule passes validation"
             (valid-application-persistence-rule? rule))

;; ── path validation：拒绝 .. / 绝对路径 / 空 ────────────────
(for-each
 (lambda (bad-backing)
   (test-assert (string-append "reject backing " bad-backing)
                (not (valid-application-persistence-rule?
                      (application-persistence-rule
                       (name 'bad) (backing bad-backing)
                       (consumer ".config/x"))))))
 '("" ".." "../x" "a/../b" "a/.." "/absolute" "data-nobackup/../x"))

(for-each
 (lambda (bad-consumer)
   (test-assert (string-append "reject consumer " bad-consumer)
                (not (valid-application-persistence-rule?
                      (application-persistence-rule
                       (name 'bad) (backing "x")
                       (consumer bad-consumer))))))
 '("" ".." "../x" "a/../b" "a/.." "/absolute"))

;; ── 拒绝整目录 consumer（.config/.local/.local/share/.cache 作为
;;    整体；其下应用子目录合法——见 persistence.md）────────────
(for-each
 (lambda (whole)
   (test-assert (string-append "reject whole-dir consumer " whole)
                (not (valid-application-persistence-rule?
                      (application-persistence-rule
                       (name 'bad) (backing "x") (consumer whole))))))
 '(".config" ".local" ".local/share" ".cache"))

;; 全局目录下的应用子目录是合法精确 consumer（任务契约：禁止的是
;; “整体”持久化；.config/<app>、.local/share/<app> 是目标模式）
(test-assert "consumer under .config/<app> is valid"
             (valid-application-persistence-rule?
              (application-persistence-rule
               (name 'ok) (backing "x") (consumer ".config/some-app"))))
(test-assert "consumer under .local/share/<app> is valid"
             (valid-application-persistence-rule?
              (application-persistence-rule
               (name 'ok) (backing "x") (consumer ".local/share/some-app"))))

;; ── exposure / lifecycle 只允许声明值 ───────────────────────
(test-assert "reject unknown exposure"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x") (consumer ".config/x")
                    (exposure 'symlink)))))
(test-assert "reject unknown lifecycle"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x") (consumer ".config/x")
                    (lifecycle 'seed-once)))))

;; ── bind-file exposure：schema / validation ──────────────────
(define bind-file-rule
  (application-persistence-rule
   (name 'bind-file-test)
   (backing "synthetic-test/state.json")   ; backing = regular file 相对路径
   (consumer ".config/synthetic-test/state.json") ; consumer = regular file
   (exposure 'bind-file)
   (lifecycle 'application-owned)))

(test-assert "bind-file rule record constructible"
             (application-persistence-rule? bind-file-rule))
(test-assert "bind-file is a legal exposure (passes validation)"
             (valid-application-persistence-rule? bind-file-rule))
(test-assert "unknown exposure still rejected alongside bind-file"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x") (consumer ".config/x")
                    (exposure 'bind-symlink)))))
(test-assert "bind-file rule with seeds is rejected (seeds are \
backing-directory-relative)"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x/state.json")
                    (consumer ".config/x/state.json")
                    (exposure 'bind-file)
                    (seeds `(("a.toml"
                              . ,(plain-file "s" "x"))))))))

;; ── bind-file 的 bind file-system 生成语义 ──────────────────
;; 必须生成 file→file bind：source/target 与 bind-directory 同构，
;; 但 create-mount-point? 为 #f（shepherd 的 mkdir-p 会建出
;; directory；regular-file 挂载点由 activation 预建——pinned Guix
;; mount-file-system 对 bind mount + non-directory source 原生自动
;; 创建 regular-file target 作为第二层防御）。
(define file-mounts (application-persistence-file-systems
                     (list bind-file-rule) "alice"))
(test-assert "bind-file rule produces one bind mount"
             (= 1 (length file-mounts)))
(define file-fs (car file-mounts))
(test-equal "bind-file bind source is /persist/data-app/<backing file>"
            "/persist/data-app/synthetic-test/state.json"
            (file-system-device file-fs))
(test-equal "bind-file bind target is /home/<user>/<consumer file>"
            "/home/alice/.config/synthetic-test/state.json"
            (file-system-mount-point file-fs))
(test-equal "bind-file bind type none"
            "none" (file-system-type file-fs))
(test-assert "bind-file bind-mount flag set"
             (memq 'bind-mount (file-system-flags file-fs)))
(test-assert "bind-file disables create-mount-point? (regular-file mount \
point, not directory)"
             (not (file-system-create-mount-point? file-fs)))
(test-assert "bind-file keeps desktop metadata options (gvfs integration)"
             (string-contains (file-system-options file-fs)
                              "x-gvfs-trash"))

;; ── coexistence：同一 application 里 bind-file 与 bind-directory ──
(define coexist-mounts
  (application-persistence-file-systems
   (list bind-file-rule rule) "alice"))
(test-equal "bind-file and bind-directory rules coexist in one mapping"
            2 (length coexist-mounts))
(test-assert "coexistence preserves per-rule create-mount-point? semantics"
             (let ((flags (map file-system-create-mount-point?
                               coexist-mounts)))
               (and (member #t flags) (member #f flags))))
(test-assert "coexistence sources stay under /persist/data-app"
             (every (lambda (m)
                      (string-prefix? "/persist/data-app/"
                                      (file-system-device m)))
                    coexist-mounts))

;; ── bind-file activation 生成：regular-file 原语在场 ────────
(test-assert "bind-file activation gexp can be generated"
             (let ((gexp (application-persistence-activation
                          (list bind-file-rule) "alice")))
               (and (gexp? gexp)
                    (pair? (gexp->approximate-sexp gexp)))))
(test-assert "bind-file activation creates regular files (no directory \
backing for the file rule)"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list bind-file-rule) "alice")))))
               (and (string-contains s "state.json")
                    (string-contains s "call-with-output-file")
                    (string-contains s "stat:type"))))
(test-assert "bind-file activation still carries consumer-parent machinery"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list bind-file-rule) "alice")))))
               (and (string-contains s "ensure-home-parent-directories!")
                    (string-contains s "chown"))))

;; ── seeds 字段（seed-once）─────────────────────────────────
(test-equal "seeds field defaults to empty"
            '()
            (application-persistence-rule-seeds
             (application-persistence-rule
              (name 'x) (backing "x") (consumer ".config/x"))))
(test-assert "rule with seeds passes validation"
             (valid-application-persistence-rule? seeded-rule))
(test-equal "seeds field round-trips targets"
            '("settings.toml")
            (map car (application-persistence-rule-seeds seeded-rule)))

;; 非法 seed：空 / .. 逃逸 / 绝对路径 / marker 后缀冲突 /
;; 非 file-like source——全部 fail closed
(for-each
 (lambda (bad-target)
   (test-assert (string-append "reject seed target " bad-target)
                (not (valid-application-persistence-rule?
                      (application-persistence-rule
                       (name 'bad) (backing "x") (consumer ".config/x")
                       (seeds `((,bad-target
                                 . ,(plain-file "s" "x")))))))))
 '("" ".." "../x" "a/../b" "a/.." "/absolute" "x.seed-provided"))
(test-assert "reject seed spec that is not a pair"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x") (consumer ".config/x")
                    (seeds '(("settings.toml")))))))
(test-assert "reject non-file-like seed source"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x") (consumer ".config/x")
                    (seeds '(("settings.toml" . "not-a-file-like")))))))

;; seed 目标必须落在 backing 内（backing/consumer 校验已保证），
;; 且不引入独立白名单：seed 只针对首次初始化，目录持久化仍是
;; 整个 consumer（bind directory）。
(test-assert "seeded rule is still a directory bind"
             (and (eq? 'bind-directory (application-persistence-rule-exposure
                                        seeded-rule))
                  (eq? 'application-owned (application-persistence-rule-lifecycle
                                           seeded-rule))))

;; ── bind file-system 生成 ───────────────────────────────────
(define mounts (application-persistence-file-systems (list rule) "alice"))
(test-assert "one bind mount per rule"
             (= 1 (length mounts)))
(define fs (car mounts))
(test-equal "bind source is /persist/data-app/<backing>"
            "/persist/data-app/synthetic-test/state"
            (file-system-device fs))
(test-equal "bind target is /home/<user>/<consumer>"
            "/home/alice/.config/synthetic-test"
            (file-system-mount-point fs))
(test-equal "bind type none"
            "none" (file-system-type fs))
(test-assert "bind-mount flag set"
             (memq 'bind-mount (file-system-flags fs)))
(test-assert "create-mount-point? set"
             (file-system-create-mount-point? fs))

(test-assert "no mapping touches /persist/data-nobackup"
             (every (lambda (m)
                      (not (string-contains (file-system-device m)
                                            "data-nobackup")))
                    (application-persistence-file-systems
                     (list rule
                           (application-persistence-rule
                            (name 'r2) (backing "other")
                            (consumer ".local/state/x")))
                     "alice")))

;; ── activation 可生成（backing 创建 + consumer parent ownership）─
(test-assert "activation gexp can be generated"
             (let ((gexp (application-persistence-activation
                          (list rule) "alice")))
               (and (gexp? gexp)
                    (pair? (gexp->approximate-sexp gexp)))))

(test-assert "activation references /persist/data-app and consumer parent"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list rule) "alice")))))
               (and (string-contains s "/persist/data-app")
                    (string-contains s "synthetic-test")
                    (string-contains s "mkdir-p")
                    (string-contains s "chown"))))

;; ── seed-once 接线：activation 含 seed 目标 / marker / 状态机 ─
(test-assert "seeded activation references seed target, marker and state machine"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list seeded-rule) "alice")))))
               (and (string-contains s "seeded-test/state")
                    (string-contains s "settings.toml")
                    (string-contains s ".seed-provided")
                    (string-contains s "seed-once-file!")
                    (string-contains s "chown"))))
(test-assert "unseeded activation carries no seed machinery"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list rule) "alice")))))
               (not (string-contains s "seed-once-file!"))))

;; ── 无 copy/sync 实现 ───────────────────────────────────────
(test-assert "no copy/sync primitives in generated artifacts"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list rule) "alice")))))
               (and (not (string-contains s "copy-file"))
                    (not (string-contains s "copy-recursively"))
                    (not (string-contains s "rsync")))))

;; ── service 构造 ────────────────────────────────────────────
;; simple-service 的 kind 是包装类型，其 extension 指向
;; activation-service-type。
(test-assert "persistence service constructed for non-empty rules"
             (let ((svc (application-persistence-service (list rule) "alice")))
               (and svc
                    (service? svc)
                    (any (lambda (ext)
                           (eq? (service-extension-target ext)
                                activation-service-type))
                         (service-type-extensions (service-kind svc))))))
(test-assert "no service for empty rules"
             (not (application-persistence-service '() "alice")))

(test-end "application-persistence")
