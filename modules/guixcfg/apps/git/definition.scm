;;; Git application unit：git 包 + 纯行为设置（不猜 user.name/email
;;; ——个人身份留待以后显式配置）。
;;;
;;; 跨 app 契约：.gitconfig include ~/.config/git/signing（由 gnupg
;;; app 贡献：user.signingkey + commit.gpgsign）。git app 依赖 gnupg
;;; app 启用——registry 打包启停；include 目标缺失时 git 报错
;;; （fail loud，不会静默弱签名）。

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
    (list (simple-service
           'git-files
           home-files-service-type
           `((".gitconfig"
              ,(plain-file
                "gitconfig"
                (string-append
                 "[init]\n\tdefaultBranch = main\n"
                 "[include]\n\tpath = ~/.config/git/signing\n")))))))))
