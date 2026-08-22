;;; Application layer 框架测试：<application> record、aggregation 与
;;; service extension 语义。只测框架机制本身（合成 fixture），不检查
;;; 具体应用的内容/列表（per-app 断言已删除——加应用不应要求改测试）。

(use-modules (guix store)         ; %store（合成 XDG lower）
             (guix monads)
             (guix derivations)
             (guix gexp)              ; plain-file、lower-object
             (guix records)           ; define-record-type*
             (ice-9 rdelim)           ; read-string
             (guixcfg apps model)
             (gnu home)              ; home-environment
             (gnu home services)     ; home-files-service-type、home-xdg-configuration-files-service-type
             (gnu home services shells) ; home-bash-service-type
             (gnu services)
             (gnu packages base)     ; hello（sample record 用）
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "apps")

;; ── record 构造与字段 ───────────────────────────────────────
(define sample
  (application
   (name 'sample)
   (home-packages (list hello))
   (home-services '())
   (system-services '())
   (persistence '())
   (secrets '())))

(test-assert "application record constructible"
             (application? sample))
(test-equal "application name" 'sample (application-name sample))
(test-equal "default home-services empty"
            '() (application-home-services sample))

;; ── aggregation：纯 concatenation（不做 same-kind merge）────
(define svc-a1 (service home-files-service-type '(("a" . 1))))
(define svc-a2 (service home-bash-service-type (home-bash-configuration)))
(define svc-b  (service home-files-service-type '(("b" . 2))))
(define app-a
  (application
   (name 'a)
   (home-packages '(pkg-a))
   (home-services (list svc-a1 svc-a2))
   (system-services '(sys-a))
   (persistence '(rule-a))
   (secrets '(sec-a))))
(define app-b
  (application
   (name 'b)
   (home-packages '(pkg-b))
   (home-services (list svc-b))))

(test-equal "applications-home-packages concatenates"
            '(pkg-a pkg-b) (applications-home-packages (list app-a app-b)))
(test-assert "applications-home-services preserves every contribution"
             (let ((svcs (applications-home-services (list app-a app-b))))
               (and (= 3 (length svcs))
                    (memq svc-a1 svcs)
                    (memq svc-a2 svcs)
                    (memq svc-b svcs))))
(test-assert "applications-home-services ordering is deterministic"
             (equal? (applications-home-services (list app-a app-b))
                     (applications-home-services (list app-a app-b))))

;; ── home-files 目标归属校验（~/.config 必须走 xdg service）────
(define bad-config-app
  (application
   (name 'bad-config)
   (home-services
    (list (service home-files-service-type '((".config/foo" . 1)))))))

(define bad-config-exact-app
  (application
   (name 'bad-config-exact)
   (home-services
    (list (service home-files-service-type '((".config" . 1)))))))

(define good-dotfile-app
  (application
   (name 'good-dotfile)
   (home-services
    (list (service home-files-service-type '((".ssh/config" . 1)
                                            (".gitconfig" . 2)))))))

(test-assert "home-files target under ~/.config/ rejected (fail fast)"
             (catch #t
               (lambda ()
                 (applications-home-services (list bad-config-app))
                 #f)
               (lambda (k . a) #t)))

(test-assert "home-files exact ~/.config target rejected"
             (catch #t
               (lambda ()
                 (applications-home-services (list bad-config-exact-app))
                 #f)
               (lambda (k . a) #t)))

(test-equal "non-config dotfile targets still aggregate"
            2 (length (service-value
                       (car (applications-home-services
                             (list good-dotfile-app))))))

;; ── service-type-extend 不是 generic same-kind merger ────────
(define-record-type* <synthetic-config> synthetic-config make-synthetic-config
                     synthetic-config?
                     (flag synthetic-config-flag))

(define synthetic-service-type
  (service-type
   (name 'synthetic-sink)
   (description "synthetic sink for service semantic tests")
   (extensions '())
   (compose concatenate)                    ; extension values: string list
   (extend (lambda (base ext-list)          ; base: <synthetic-config>
             (synthetic-config
              (flag (and (synthetic-config-flag base)
                         (every (lambda (s) (string=? "ok" s)) ext-list))))))
   (default-value (synthetic-config (flag #t)))))

(define synth-extend (service-type-extend synthetic-service-type))

(test-assert "compose+extend: (base, extension-list) is the legal call"
             (synthetic-config-flag
              (synth-extend (synthetic-config (flag #t)) '("ok" "ok"))))

(test-assert "extension value semantics differ from base value"
             (not (synthetic-config-flag
                   (synth-extend (synthetic-config (flag #t)) '("bad")))))

(test-assert "extend(base1, base2) is invalid: base values are not extension values"
             (catch #t
               (lambda ()
                 (synth-extend (synthetic-config (flag #t))
                               (synthetic-config (flag #t)))
                 #f)
               (lambda (k . a) #t)))

(test-equal "compose concatenates the extension value list"
            '("a" "b")
            ((service-type-compose synthetic-service-type) '(("a") ("b"))))

;; ── aggregator purity：不调用 merge 相关 API ─────────────────
(test-assert "applications-home-services is pure concatenation (no merge logic)"
             (let ((s (call-with-input-file "modules/guixcfg/apps/model.scm"
                                            (lambda (p) (read-string p)))))
               (let* ((start (string-contains s "(define (applications-home-services"))
                      (end (string-contains s "(define (applications-system-services"))
                      (body (substring s start end)))
                 (and (string-contains body "append-map")
                      (not (string-contains body "service-kind"))
                      (not (string-contains body "service-type-extend"))
                      (not (string-contains body "service-type-compose"))
                      (not (string-contains body "merge"))))))

;; ── 多路 XDG extension：lower 成功且全部贡献在场（合成 fixture）─
(define synthetic-xdg-app
  (application
   (name 'synthetic-xdg)
   (home-services
    (list (simple-service 'synthetic-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("synthetic/config.ini"
                             ,(plain-file "synthetic.ini" "x=1"))))))))

(define synthetic-xdg-app-2
  (application
   (name 'synthetic-xdg-2)
   (home-services
    (list (simple-service 'synthetic-xdg-config-2
                          home-xdg-configuration-files-service-type
                          `(("synthetic/other.ini"
                             ,(plain-file "other.ini" "y=2"))))))))

(define %composed-home
  (home-environment
   (packages '())
   (services (applications-home-services
              (list synthetic-xdg-app synthetic-xdg-app-2)))))

(define %store (open-connection))
(define %composed-drv (run-with-store %store (lower-object %composed-home)))
(build-derivations %store (list %composed-drv))
(define %composed-out (derivation->output-path %composed-drv))

(test-assert "multi-way XDG composition lowers without ambiguous target"
             (and %composed-out
                  (file-exists? %composed-out)))

(test-assert "every synthetic contribution present in the composed home"
             (and (file-exists?
                   (string-append %composed-out
                                  "/files/.config/synthetic/config.ini"))
                  (file-exists?
                   (string-append %composed-out
                                  "/files/.config/synthetic/other.ini"))))

(test-end "apps")
