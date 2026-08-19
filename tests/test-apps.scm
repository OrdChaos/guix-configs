;;; Application layer 测试：<application> record、aggregation、
;;; registry 显式启用与名字唯一性。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
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

;; ── aggregation ─────────────────────────────────────────────
(define app-a
  (application
   (name 'a)
   (home-packages '(pkg-a))
   (home-services '(svc-a1 svc-a2))
   (system-services '(sys-a))
   (persistence '(rule-a))
   (secrets '(sec-a))))
(define app-b
  (application
   (name 'b)
   (home-packages '(pkg-b))
   (home-services '(svc-b))))

(test-equal "applications-home-packages concatenates"
            '(pkg-a pkg-b) (applications-home-packages (list app-a app-b)))
(test-equal "applications-home-services concatenates"
            '(svc-a1 svc-a2 svc-b)
            (applications-home-services (list app-a app-b)))
(test-equal "applications-system-services concatenates"
            '(sys-a) (applications-system-services (list app-a app-b)))
(test-equal "applications-persistence concatenates"
            '(rule-a) (applications-persistence (list app-a app-b)))
(test-equal "applications-secrets concatenates"
            '(sec-a) (applications-secrets (list app-a app-b)))
(test-equal "empty registry aggregates to empty lists"
            '() (applications-home-packages '()))

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
