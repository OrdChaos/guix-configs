;;; Minimal Guix Home 测试：模块加载、配置求值、包集合、
;;; bash 环境变量与 Git config 声明。

(use-modules (guixcfg home user)
             (guixcfg home packages)
             (gnu home)
             (gnu home services)        ; home-files-service-type
             (gnu home services shells) ; home-bash-service-type
             (gnu services guix)        ; guix-home-service-type
             (guix packages)          ; package-name
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "home")

(test-assert "%guix-home 是可用的 home-environment"
             (home-environment? %guix-home))

(test-assert "home packages 非空"
             (pair? (home-environment-packages %guix-home)))

(test-assert "home packages 只含 normal-user CLI 工具"
             (every (lambda (p)
                      (not (member (package-name p)
                                   '("cryptsetup" "btrfs-progs" "tpm2-tools"
                                                  "sbkeysync" "efibootmgr"))))
                    (home-environment-packages %guix-home)))

;; bash 环境变量声明（EDITOR/VISUAL/PAGER）
(define bash-svc
  (find (lambda (s) (eq? (service-kind s) home-bash-service-type))
        (home-environment-services %guix-home)))
(test-assert "home-bash service present"
             bash-svc)

;; Git config 文件声明（~/.gitconfig）
(define files-svc
  (find (lambda (s) (eq? (service-kind s) home-files-service-type))
        (home-environment-services %guix-home)))
(test-assert "home-files service present (gitconfig)"
             (and files-svc
                  (assoc ".gitconfig" (service-value files-svc))))

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
