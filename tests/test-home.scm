;;; Minimal Guix Home 测试：模块加载、配置求值、包集合、
;;; bash 环境变量与 Git config 声明。

(use-modules (guixcfg home user)
             (guixcfg home packages)
             (gnu home)
             (gnu home services)        ; home-files-service-type
             (gnu home services shells) ; home-bash-service-type
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

(test-end "home")
