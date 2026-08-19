;;; Guix Home 测试：模块加载、薄 assembly（registry 聚合）、
;;; bash/Git/niri/D-Bus/PipeWire 最终 capability 仍存在、
;;; source-relative local-file 不依赖 shell CWD。

(use-modules (guixcfg home user)
             (guixcfg apps model)
             (guixcfg apps registry)
             (gnu home)
             (gnu home services)        ; home-files-service-type
             (gnu home services shells) ; home-bash-service-type
             (gnu home services desktop) ; home-dbus-service-type
             (gnu home services niri)   ; home-niri-service-type
             (gnu home services sound)  ; home-pipewire-service-type
             (gnu services guix)        ; guix-home-service-type
             (guix gexp)                ; local-file-absolute-file-name
             (guix packages)          ; package-name
             (srfi srfi-1)
             (srfi srfi-13)           ; string-suffix?
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "home")

(test-assert "%guix-home is a usable home-environment"
             (home-environment? %guix-home))

(test-assert "home packages non-empty"
             (pair? (home-environment-packages %guix-home)))

(test-assert "home packages only contain normal-user CLI tools"
             (every (lambda (p)
                      (not (member (package-name p)
                                   '("cryptsetup" "btrfs-progs" "tpm2-tools"
                                                  "sbkeysync" "efibootmgr"))))
                    (home-environment-packages %guix-home)))

;; 薄 assembly：packages 与 registry aggregation 全等；services 是
;; registry 贡献的超集（home-environment 会附加隐式服务——
;; home-shepherd/home-activation/symlink-manager 等）。
(test-assert "home packages equal registry aggregation"
             (equal? (home-environment-packages %guix-home)
                     (applications-home-packages %applications)))
(test-assert "home services include every registry service"
             (every (lambda (s)
                      (any (lambda (h)
                             (eq? (service-kind h) (service-kind s)))
                           (home-environment-services %guix-home)))
                    (applications-home-services %applications)))

;; bash 环境变量声明（EDITOR/VISUAL/PAGER）仍存在
(define bash-svc
  (find (lambda (s) (eq? (service-kind s) home-bash-service-type))
        (home-environment-services %guix-home)))
(test-assert "home-bash service present"
             bash-svc)

;; Git config 文件声明（~/.gitconfig）仍存在
(define files-svc
  (find (lambda (s) (eq? (service-kind s) home-files-service-type))
        (home-environment-services %guix-home)))
(test-assert "home-files service present (gitconfig)"
             (and files-svc
                  (assoc ".gitconfig" (service-value files-svc))))

;; M2 桌面 capability：D-Bus / Niri / PipeWire 服务仍存在
(test-assert "home-dbus service present"
             (any (lambda (s) (eq? (service-kind s) home-dbus-service-type))
                  (home-environment-services %guix-home)))
(test-assert "home-niri service present"
             (any (lambda (s) (eq? (service-kind s) home-niri-service-type))
                  (home-environment-services %guix-home)))
(test-assert "home-pipewire service present"
             (any (lambda (s) (eq? (service-kind s) home-pipewire-service-type))
                  (home-environment-services %guix-home)))

;; niri config 仍由 Home XDG file service 声明，且是 source-relative
;; local-file（解析到 apps/niri/config.kdl，不依赖 shell CWD——
;; pinned Guix local-file 宏按出现处 source directory 解析）。
(define xdg-svc
  (find (lambda (s) (eq? (service-kind s) home-xdg-configuration-files-service-type))
        (home-environment-services %guix-home)))
(test-assert "niri config declared via home-xdg-configuration-files"
             (and xdg-svc
                  (assoc "niri/config.kdl" (service-value xdg-svc))))

(test-assert "niri config is a source-relative local-file under apps/niri/"
             (let* ((entry (assoc "niri/config.kdl" (service-value xdg-svc)))
                    (lf (cadr entry))
                    (abs (local-file-absolute-file-name lf)))
               (and (local-file? lf)
                    (string-suffix? "/modules/guixcfg/apps/niri/config.kdl"
                                    abs)
                    (file-exists? abs))))

;; Guix Home 挂入 system（官方 guix-home-service-type）：home-environment
;; 随 system generation 构建，boot 时以用户身份运行其 activate，重建
;; ephemeral $HOME 中的 ~/.guix-home 与 dotfile 链接（指向本 generation
;; closure 内的 home，而非 mutable 记录）。
(define gh-svc
  (service guix-home-service-type `(("user" ,%guix-home))))
(test-assert "guix-home-service-type binds %guix-home"
             (and (eq? (service-kind gh-svc) guix-home-service-type)
                  (eq? (cadr (car (service-value gh-svc))) %guix-home)))

(test-end "home")
