;;; Guix Home 框架测试：模块加载、薄 assembly（registry 聚合与
;;; 策略服务组合）、系统工具不进入 home profile。不检查具体应用
;;; 内容（per-app 断言已删除——加应用不应要求改测试）。

(use-modules (guixcfg home user)
             (guixcfg home fonts)        ; %fonts、%home-fonts-xdg-link-service
             (guixcfg apps model)
             (guixcfg apps registry)
             (gnu home)
             (gnu home services)        ; home-files-service-type
             (gnu home services fontutils) ; home-fontconfig-service-type
             (gnu home services xdg)    ; home-xdg-mime-applications-service-type
             (gnu services)              ; service-kind、service-type-extensions、service-extension-target
             (gnu services guix)        ; guix-home-service-type
             (gnu packages fontutils)   ; fontconfig
             (guix packages)          ; package-name
             (srfi srfi-1)
             (srfi srfi-13)           ; string-prefix?、string-drop
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "home")

(test-assert "%guix-home is a usable home-environment"
             (home-environment? %guix-home))

(test-assert "home packages non-empty"
             (pair? (home-environment-packages %guix-home)))

;; 条目可以是 package 或 (package output) tuple（manifest 合法
;; 形式，如 (list glib "bin")——apps/gtk 的 gsettings CLI）。
(test-assert "home packages only contain normal-user CLI tools"
             (every (lambda (p)
                      (not (member (package-name (if (package? p) p (car p)))
                                   '("cryptsetup" "btrfs-progs" "tpm2-tools"
                                                  "sbkeysync" "efibootmgr"))))
                    (home-environment-packages %guix-home)))

;; 薄 assembly：packages 是「字体集合 + registry 聚合」的精确组合；
;; services 是 registry 贡献 + 策略服务的超集（home-environment 会
;; 附加隐式服务——home-shepherd/home-activation/symlink-manager 等）。
(test-assert "home packages equal fonts + registry aggregation"
             (equal? (home-environment-packages %guix-home)
                     (append %fonts
                             (applications-home-packages %applications))))
(test-assert "home services include every registry service"
             (every (lambda (s)
                      (any (lambda (h)
                             (eq? (service-kind h) (service-kind s)))
                           (home-environment-services %guix-home)))
                    (applications-home-services %applications)))

;; 组合层级：统一 XDG/default-apps 策略服务（guixcfg home xdg）也
;; 在 %guix-home 中（应用模块不再各自声明默认应用）
(test-assert "xdg-default-apps policy service composed into %guix-home"
             (any (lambda (s)
                    (any (lambda (ext)
                           (eq? (service-extension-target ext)
                                home-xdg-mime-applications-service-type))
                         (service-type-extensions (service-kind s))))
                  (home-environment-services %guix-home)))

(test-assert "xdg user directories service composed into %guix-home"
             (any (lambda (s)
                    (eq? 'home-xdg-user-directories
                         (service-type-name (service-kind s))))
                  (home-environment-services %guix-home)))

(test-assert "fontconfig policy service composed into %guix-home"
             (any (lambda (s)
                    (any (lambda (ext)
                           (eq? (service-extension-target ext)
                                home-fontconfig-service-type))
                         (service-type-extensions (service-kind s))))
                  (home-environment-services %guix-home)))

;; XDG 字体链接农场：CEF 环境清洗型渲染进程的唯一可达字体目录
;; （modules/guixcfg/home/fonts.scm 头部诊断链）。断言服务组合进
;; %guix-home、覆盖全部字体包、target 均为 .local/share/fonts/
;; 下以包名命名的目录链接。
(define %fonts-xdg-link-svc
  (find (lambda (s)
          (eq? 'home-fonts-xdg-links
               (service-type-name (service-kind s))))
        (home-environment-services %guix-home)))

(test-assert "home fonts xdg link service composed into %guix-home"
             %fonts-xdg-link-svc)

(test-equal "home fonts xdg links cover every font package"
            (map package-name
                 (filter (lambda (pkg)
                           (not (member pkg %home-fonts-xdg-link-exclusions)))
                         %fonts))
            (map (lambda (entry)
                   (string-drop (car entry)
                                (string-length ".local/share/fonts/")))
                 (service-value %fonts-xdg-link-svc)))

(test-assert "home fonts xdg link targets are safe home-relative paths"
             (every (lambda (entry)
                      (and (string-prefix? ".local/share/fonts/" (car entry))
                           (not (string-contains (car entry) ".."))))
                    (service-value %fonts-xdg-link-svc)))

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
