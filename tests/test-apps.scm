;;; Application layer 测试：<application> record、aggregation、
;;; registry 显式启用与名字唯一性。

(use-modules (guix store)         ; %store（三路 XDG lower）
             (guix monads)
             (guix derivations)
             (guix gexp)              ; plain-file、local-file、lower-object
             (guix records)           ; define-record-type*
             (ice-9 rdelim)           ; read-string
             (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg apps niri definition)   ; %niri（三路 XDG）
             (guixcfg apps mpv definition)    ; %mpv（三路 XDG）
             (gnu home)              ; home-environment
             (gnu home services)     ; home-files-service-type、home-xdg-configuration-files-service-type
             (gnu home services shells) ; home-bash-service-type
             (gnu home services desktop) ; home-dbus-service-type
             (gnu home services niri)   ; home-niri-service-type
             (gnu home services sound)  ; home-pipewire-service-type
             (gnu services)
             (guix gexp)             ; local-file-absolute-file-name
             (gnu packages base)     ; hello（sample record 用）
             (guix packages)         ; package-name
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

;; ── 三路 XDG extension：lower 成功且全部贡献在场 ────────────
(define synthetic-xdg-app
  (application
   (name 'synthetic-xdg)
   (home-services
    (list (simple-service 'synthetic-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("synthetic/config.ini"
                             ,(plain-file "synthetic.ini" "x=1"))))))))

(define %three-way-home
  (home-environment
   (packages '())
   (services (applications-home-services
              (list %niri %mpv synthetic-xdg-app)))))

(define %store (open-connection))
(define %three-way-drv
  (run-with-store %store (lower-object %three-way-home)))
(build-derivations %store (list %three-way-drv))
(define %three-way-out (derivation->output-path %three-way-drv))

(test-assert "three-way XDG composition lowers without ambiguous target"
             (and %three-way-out
                  (file-exists? %three-way-out)))

(test-assert "niri config present in the composed home"
             (file-exists?
              (string-append %three-way-out
                             "/files/.config/niri/config.kdl")))

(test-assert "mpv configs present in the composed home"
             (and (file-exists?
                   (string-append %three-way-out
                                  "/files/.config/mpv/mpv.conf"))
                  (file-exists?
                   (string-append %three-way-out
                                  "/files/.config/mpv/input.conf"))))

(test-assert "synthetic contribution present in the composed home"
             (file-exists?
              (string-append %three-way-out
                             "/files/.config/synthetic/config.ini")))


;; ── registry ────────────────────────────────────────────────
(test-assert "registry module loads; %applications is a non-empty list"
             (and (pair? %applications)
                  (every application? %applications)))

(test-assert "application names are unique"
             (let ((names (map application-name %applications)))
               (= (length names) (length (delete-duplicates names)))))

(test-assert "all application names are symbols"
             (every symbol? (map application-name %applications)))

;; ── 迁移契约：home 组合来自 registry，而非旧横向 inventory ──
;; （旧 (guixcfg home packages) 已删除；test-home.scm 断言最终
;; capability 仍存在。）
(test-assert "registry contributes home packages"
             (pair? (applications-home-packages %applications)))

(test-assert "git app owns the git package"
             (let ((git-app (find (lambda (a) (eq? 'git (application-name a)))
                                  %applications)))
               (and git-app
                    (member "git" (map package-name
                                       (application-home-packages git-app))))))

(test-assert "service-owned packages are not re-declared in apps"
             ;; niri/pipewire/wireplumber/xwayland-satellite/dbus 由官方
             ;; Home services 自动贡献；没有任何 app 重复声明。
             (let ((all (append-map application-home-packages %applications)))
               (every (lambda (p)
                        (not (member (package-name p)
                                     '("niri" "pipewire" "wireplumber"
                                       "xwayland-satellite" "dbus"))))
                      all)))

(test-end "apps")
