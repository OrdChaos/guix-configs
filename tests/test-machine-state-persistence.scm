;;; Machine-state persistence generic engine 测试：synthetic rules 验证
;;; 机制（当前无 production rule——本文件不 invent 真实 daemon 规则；
;;; NetworkManager 只作为 docs example，不依赖其 package/service）。
;;;
;;; 覆盖：root 派生自 persist-mount-point、backing/consumer 生成、
;;; bind projection、machine-owned lifecycle、validation（absolute
;;; backing / .. / empty / 非 absolute consumer / 禁止 roots 拒绝）、
;;; 无 data-app backing、无 HOME-relative consumer、无 copy/sync、
;;; 无 production rule。

(use-modules (guixcfg system machine-state-persistence)
             (guixcfg storage model)   ; persist-mount-point
             (gnu services)
             (gnu system file-systems)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "machine-state-persistence")

;; ── root 派生（单一 authority：persist-mount-point @persist-system）──
(test-equal "machine-state root derives from @persist-system"
            "/persist/system/state"
            %machine-state-root)
(test-assert "machine-state root is under /persist/system"
             (string-prefix? (persist-mount-point "@persist-system")
                             %machine-state-root))

;; ── synthetic rule（测试专用；机制验证）──────────────────────
(define rule
  (machine-state-persistence-rule
   (name 'synthetic-daemon)
   (backing "synthetic-daemon/state")
   (consumer "/etc/example-daemon/state")
   (exposure 'bind-directory)
   (lifecycle 'machine-owned)))

(test-assert "rule record constructible"
             (machine-state-persistence-rule? rule))
(test-equal "exposure default is bind-directory"
            'bind-directory
            (machine-state-persistence-rule-exposure
             (machine-state-persistence-rule
              (name 'x) (backing "x") (consumer "/etc/x"))))
(test-equal "lifecycle default is machine-owned"
            'machine-owned
            (machine-state-persistence-rule-lifecycle
             (machine-state-persistence-rule
              (name 'x) (backing "x") (consumer "/etc/x"))))
(test-assert "valid rule passes validation"
             (valid-machine-state-persistence-rule? rule))

;; ── backing validation：absolute / .. / empty 拒绝 ──────────
(for-each
 (lambda (bad)
   (test-assert (string-append "reject backing " bad)
                (not (valid-machine-state-persistence-rule?
                      (machine-state-persistence-rule
                       (name 'bad) (backing bad)
                       (consumer "/etc/x"))))))
 '("" ".." "../x" "a/../b" "a/.." "/absolute"))

;; ── consumer validation：必须 absolute；禁止 roots 拒绝 ──────
(for-each
 (lambda (bad)
   (test-assert (string-append "reject consumer " bad)
                (not (valid-machine-state-persistence-rule?
                      (machine-state-persistence-rule
                       (name 'bad) (backing "x")
                       (consumer bad))))))
 '("" "etc/x" "relative/path" "/" "/etc/x/"
   "/gnu/store/foo" "/run/foo" "/persist/foo"
   "/persist/system/state/x" "/home/user/x" "/home/x"
   "/proc/x" "/sys/x" "/dev/x" "/tmp/x"))

;; 合法 absolute consumer 通过
(test-assert "valid absolute consumers accepted"
             (every (lambda (c)
                      (valid-machine-state-persistence-rule?
                       (machine-state-persistence-rule
                        (name 'ok) (backing "x") (consumer c))))
                    '("/etc/example-daemon/state"
                      "/var/lib/example-daemon"
                      "/etc/NetworkManager/system-connections"
                      "/var/lib/NetworkManager")))

;; ── exposure / lifecycle 只允许声明值 ───────────────────────
(test-assert "reject unknown exposure"
             (not (valid-machine-state-persistence-rule?
                   (machine-state-persistence-rule
                    (name 'bad) (backing "x") (consumer "/etc/x")
                    (exposure 'symlink)))))
(test-assert "reject unknown lifecycle"
             (not (valid-machine-state-persistence-rule?
                   (machine-state-persistence-rule
                    (name 'bad) (backing "x") (consumer "/etc/x")
                    (lifecycle 'application-owned)))))

;; ── bind file-system 生成 ───────────────────────────────────
(define mounts (machine-state-persistence-file-systems (list rule)))
(test-assert "one bind mount per rule"
             (= 1 (length mounts)))
(define fs (car mounts))
(test-equal "bind source is /persist/system/state/<backing>"
            "/persist/system/state/synthetic-daemon/state"
            (file-system-device fs))
(test-equal "bind target is the absolute consumer"
            "/etc/example-daemon/state"
            (file-system-mount-point fs))
(test-equal "bind type none"
            "none" (file-system-type fs))
(test-assert "bind-mount flag set"
             (memq 'bind-mount (file-system-flags fs)))
(test-assert "create-mount-point? set"
             (file-system-create-mount-point? fs))

(test-assert "no /persist/data-app backing generated"
             (every (lambda (m)
                      (not (string-contains (file-system-device m)
                                            "/persist/data-app")))
                    (machine-state-persistence-file-systems
                     (list rule
                           (machine-state-persistence-rule
                            (name 'r2) (backing "other")
                            (consumer "/var/lib/example-daemon"))))))

(test-assert "no HOME-relative consumer generated"
             (every (lambda (m)
                      (not (string-prefix? "/home/" (file-system-mount-point m))))
                    (machine-state-persistence-file-systems
                     (list rule
                           (machine-state-persistence-rule
                            (name 'r2) (backing "other")
                            (consumer "/var/lib/example-daemon"))))))

;; ── activation 可生成（backing + consumer parent；root-owned）──
(test-assert "activation gexp can be generated"
             (let ((gexp (machine-state-persistence-activation (list rule))))
               (and (gexp? gexp)
                    (pair? (gexp->approximate-sexp gexp)))))

(test-assert "activation references machine-state root and consumer parent"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (machine-state-persistence-activation (list rule))))))
               (and (string-contains s "/persist/system/state")
                    (string-contains s "synthetic-daemon")
                    (string-contains s "example-daemon")
                    (string-contains s "mkdir-p"))))

;; ── 无 copy/sync 实现 ───────────────────────────────────────
(test-assert "no copy/sync primitives in generated artifacts"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (machine-state-persistence-activation (list rule))))))
               (and (not (string-contains s "copy-file"))
                    (not (string-contains s "copy-recursively"))
                    (not (string-contains s "rsync")))))

;; ── service 构造 ────────────────────────────────────────────
(test-assert "service constructed for non-empty rules"
             (let ((svc (machine-state-persistence-service (list rule))))
               (and svc
                    (service? svc)
                    (any (lambda (ext)
                           (eq? (service-extension-target ext)
                                activation-service-type))
                         (service-type-extensions (service-kind svc))))))
(test-assert "no service for empty rules"
             (not (machine-state-persistence-service '())))

(test-end "machine-state-persistence")
