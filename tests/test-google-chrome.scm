;;; Google Chrome application unit 测试（docs/architecture/
;;; persistence.md production consumers；教程见 docs/development/
;;; applications.md E5/E9）。
;;;
;;; 覆盖：
;;;   1.  %google-chrome-stable 在 registry；
;;;   2.  package contribution 来自 (nongnu packages chrome)（home-packages
;;;       含 google-chrome-stable，可解析、版本非空）；
;;;   3-4. 恰好一个 persistence rule，字段精确；
;;;   5.  consumer 是官方 User Data Directory（.config/google-chrome）；
;;;   6.  不持久化 .cache/google-chrome（无任何 .cache rule）；
;;;   7.  backing 位于 /persist/data-app/google-chrome-stable/...；
;;;   8.  rule 通过 generic validation；
;;;   9.  无 secrets / 无 system services / 无 home services；
;;;   10. generic application-persistence 不知道 chrome；
;;;   11. 不复制 nonguix package 定义（无 source URL literal）；
;;;   12. 无 keyring hack（无 --password-store=basic）；
;;;   13. 无 CWD/checkout 依赖。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg apps google-chrome-stable definition)
             (guixcfg system application-persistence)
             (gnu system file-systems)  ; file-system-device
             (guix packages)            ; package-name、package-version
             (ice-9 rdelim)             ; read-string
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "google-chrome")

(define chrome-app
  (find (lambda (a) (eq? 'google-chrome-stable (application-name a)))
        %applications))

;; ── 1：registry ─────────────────────────────────────────────
(test-assert "google-chrome-stable is in the registry"
             (and chrome-app (application? chrome-app)))

;; ── 2：package contribution（nonguix 官方包，不复制定义）─────
(test-assert "google-chrome-stable package contributed via home-packages"
             (member "google-chrome-stable"
                     (map package-name (application-home-packages chrome-app))))

(test-assert "package resolves (version set, x86_64-linux supported)"
             (let ((p (car (application-home-packages chrome-app))))
               (and (string? (package-version p))
                    (> (string-length (package-version p)) 0)
                    (member "x86_64-linux" (package-supported-systems p)))))

;; ── 3-8：exactly one persistence rule，字段精确 ─────────────
(define rules (application-persistence chrome-app))

(test-assert "exactly one persistence rule"
             (= 1 (length rules)))

(define rule (car rules))
(test-equal "rule name"
            'user-data (application-persistence-rule-name rule))
(test-equal "backing is /persist/data-app relative"
            "google-chrome-stable/user-data"
            (application-persistence-rule-backing rule))
(test-equal "consumer is the official User Data Directory"
            ".config/google-chrome"
            (application-persistence-rule-consumer rule))
(test-equal "exposure is bind-directory"
            'bind-directory (application-persistence-rule-exposure rule))
(test-equal "lifecycle is application-owned"
            'application-owned (application-persistence-rule-lifecycle rule))
(test-assert "rule passes validation"
             (valid-application-persistence-rule? rule))

(test-assert "backing resolves under /persist/data-app/google-chrome-stable/"
             (let ((fs (car (application-persistence-file-systems rules "alice"))))
               (string-prefix? "/persist/data-app/google-chrome-stable/"
                               (file-system-device fs))))

(test-assert "no persistence rule covers .cache (cache stays ephemeral)"
             (every (lambda (r)
                      (not (string-prefix? ".cache"
                                           (application-persistence-rule-consumer r))))
                    rules))

;; ── 9：无 secrets / 无 system / 无 home services ────────────
(test-assert "chrome declares no secrets"
             (null? (application-secrets chrome-app)))
(test-assert "chrome declares no system services"
             (null? (application-system-services chrome-app)))
(test-assert "chrome declares no home services (package + persistence only)"
             (null? (application-home-services chrome-app)))

;; ── 10-11：generic executor 无知 + 不复制 nonguix 定义 ──────
(test-assert "generic application-persistence knows no chrome"
             (let ((s (call-with-input-file
                       "modules/guixcfg/system/application-persistence.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "chrome"))))

(test-assert "definition does not copy the nonguix package source (no URL literal)"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/google-chrome-stable/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "dl.google.com"))
                    (not (string-contains s "define-public")))))

;; ── 12：keyring 集成不 hack ─────────────────────────────────
(test-assert "no --password-store flag (uses existing Secret Service)"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/google-chrome-stable/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "--password-store"))))

;; ── 13：无 CWD/checkout 依赖 ────────────────────────────────
(test-assert "chrome definition has no CWD/checkout dependence"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/google-chrome-stable/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "getcwd"))
                    (not (string-contains s "current-filename"))
                    (not (string-contains s "/home/")))))

(test-end "google-chrome")
