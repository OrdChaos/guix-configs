;;; Application persistence generic engine 测试：synthetic rules 验证
;;; 机制（当前无 production rule——本文件不 invent 任何真实应用）。
;;;
;;; 覆盖：backing/consumer 生成、bind file-system source/target、
;;; path validation（..、绝对路径、空、整目录 consumer 拒绝）、
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
