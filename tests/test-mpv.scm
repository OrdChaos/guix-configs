;;; mpv application unit 测试——第一个真实 production
;;; application-persistence consumer（B8，docs/development/
;;; applications.md）。
;;;
;;; 覆盖：
;;;   1.  %mpv 在 registry；
;;;   2.  package contribution（home-packages 含 mpv；不在 generic
;;;        global list——无 home/packages.scm）；
;;;   3-4. mpv.conf / input.conf 是 source-relative local-file
;;;        （解析到 apps/mpv/，不依赖 CWD）；
;;;   5.  Home config target 正确（~/.config/mpv/mpv.conf、input.conf）；
;;;   6.  exactly 一个 persistence rule，字段精确；
;;;   7.  backing 位于 /persist/data-app/mpv/...；
;;;   8.  consumer 是 app-private state path（.local/state/mpv）；
;;;   9.  不持久化 .config/mpv；
;;;   10. 不持久化整个 .local/state；
;;;   11. 不使用 machine-state persistence；
;;;   12. 不声明 secret；
;;;   13. generic application-persistence 不知道 mpv；
;;;   14. 无 runtime repo dependency / CWD-based source resolution。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg apps mpv definition)
             (guixcfg system application-persistence)
             (gnu home services)        ; home-xdg-configuration-files-service-type
             (gnu services)
             (gnu system file-systems)  ; file-system-device
             (guix gexp)                ; local-file-absolute-file-name
             (guix packages)            ; package-name
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "mpv")

(define mpv-app
  (find (lambda (a) (eq? 'mpv (application-name a)))
        %applications))

;; ── 1：registry ─────────────────────────────────────────────
(test-assert "mpv is in the registry"
             (and mpv-app (application? mpv-app)))

;; ── 2：package contribution ─────────────────────────────────
(test-assert "mpv package contributed via home-packages"
             (member "mpv" (map package-name
                                 (application-home-packages mpv-app))))

(test-assert "mpv is not in a generic global package list"
             (not (file-exists? "modules/guixcfg/home/packages.scm")))

;; ── 3-4：source-relative config files ───────────────────────
(define xdg-svc
  (find (lambda (s)
          (eq? (service-kind s) home-xdg-configuration-files-service-type))
        (application-home-services mpv-app)))

(test-assert "mpv declares both config files via XDG service"
             (and xdg-svc
                  (assoc "mpv/mpv.conf" (service-value xdg-svc))
                  (assoc "mpv/input.conf" (service-value xdg-svc))))

(for-each
 (lambda (target-name file-name)
   (test-assert (string-append "config is source-relative under apps/mpv/: "
                               target-name)
                (let* ((lf (cadr (assoc target-name (service-value xdg-svc))))
                       (abs (local-file-absolute-file-name lf)))
                  (and (local-file? lf)
                       (string-suffix? (string-append
                                        "/modules/guixcfg/apps/mpv/" file-name)
                                       abs)
                       (file-exists? abs)))))
 '("mpv/mpv.conf" "mpv/input.conf")
 '("mpv.conf" "input.conf"))

;; ── 5：Home config target ───────────────────────────────────
(test-assert "Home config targets are ~/.config/mpv/..."
             (and (assoc "mpv/mpv.conf" (service-value xdg-svc))
                  (assoc "mpv/input.conf" (service-value xdg-svc))))

;; ── 6-10：exactly one persistence rule，字段精确 ────────────
(define rules (application-persistence mpv-app))

(test-assert "exactly one persistence rule"
             (= 1 (length rules)))

(define rule (car rules))
(test-equal "rule name"
            'state (application-persistence-rule-name rule))
(test-equal "backing is /persist/data-app relative"
            "mpv/state" (application-persistence-rule-backing rule))
(test-equal "consumer is the app-private state dir"
            ".local/state/mpv" (application-persistence-rule-consumer rule))
(test-equal "exposure is bind-directory"
            'bind-directory (application-persistence-rule-exposure rule))
(test-equal "lifecycle is application-owned"
            'application-owned (application-persistence-rule-lifecycle rule))
(test-assert "rule passes validation"
             (valid-application-persistence-rule? rule))

(test-assert "backing resolves under /persist/data-app/mpv/"
             (let ((fs (car (application-persistence-file-systems rules "alice"))))
               (string-prefix? "/persist/data-app/mpv/"
                               (file-system-device fs))))

(test-assert "consumer is not .config/mpv (declarative stays repo-owned)"
             (not (string=? ".config/mpv" (application-persistence-rule-consumer rule))))

(test-assert "consumer is not the whole .local/state"
             (not (string=? ".local/state" (application-persistence-rule-consumer rule))))

;; ── 11-12：无 machine-state / 无 secret ─────────────────────
(test-assert "mpv declares no machine-state persistence"
             (null? (filter (lambda (r)
                              (eq? 'machine-owned
                                   (application-persistence-rule-lifecycle r)))
                            rules)))
(test-assert "mpv declares no secrets"
             (null? (application-secrets mpv-app)))

;; ── 13-14：generic executor 无知 + 无 runtime repo dependency ──
(test-assert "generic application-persistence knows no mpv"
             (let ((s (call-with-input-file
                       "modules/guixcfg/system/application-persistence.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "mpv"))))

(test-assert "mpv definition has no CWD/checkout dependence"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/mpv/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "getcwd"))
                    (not (string-contains s "current-filename"))
                    (not (string-contains s "/home/")))))

(test-end "mpv")
