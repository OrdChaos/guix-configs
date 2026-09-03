;;; Git application unit：git 包 + 默认身份（%git-identity-name /
;;; %git-identity-email，与主机全局 git 身份一致）+ 默认分支 master
;;; （纯行为设置；单一用户环境，身份是 host policy 而非猜测）。
;;;
;;; 本文件是仓库内开发身份的唯一权威来源：身份字符串只允许出现在
;;; 这里（tests/test-source-hygiene.scm 对本文件豁免 "ordchaos"
;;; 负向扫描、并正向断言身份字面量的精确形态——防扩散；AGENT.md
;;; §13 与 users/ 的 %primary-user 例外同理）。
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

;; 默认提交身份：与主机全局 git 身份一致（OrdChaos
;; <orderchaos@ordchaos.com>），作为仓库内 Guix Home 的
;; .gitconfig [user] 默认值。
(define %git-identity-name "OrdChaos")
(define %git-identity-email "orderchaos@ordchaos.com")

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
                 "[user]\n\tname = " %git-identity-name "\n"
                 "\temail = " %git-identity-email "\n"
                 "[init]\n\tdefaultBranch = master\n"
                 "[include]\n\tpath = ~/.config/git/signing\n")))))))))
