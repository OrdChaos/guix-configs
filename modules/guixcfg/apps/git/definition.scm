;;; Git application unit：git 包 + 纯行为设置（不猜 user.name/email
;;; ——个人身份留待以后显式配置）。

(define-module (guixcfg apps git definition)
               #:use-module (gnu packages version-control) ; git
               #:use-module (gnu home services)           ; home-files-service-type
               #:use-module (gnu services)                ; service
               #:use-module (guix gexp)                   ; plain-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%git))

(define %git
  (application
   (name 'git)
   (home-packages (list git))
   (home-services
    (list (simple-service 'git-files
                          home-files-service-type
                          `((".gitconfig"
                             ,(plain-file
                               "gitconfig"
                               "[init]\n\tdefaultBranch = main\n"))))))))
