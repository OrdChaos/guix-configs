;;; Git application unit：git 包 + 默认身份 + 默认分支 master。
;;; 默认身份与 init.defaultBranch 声明在同目录 gitconfig 静态文件
;;; （.gitconfig 直接 colocate，无内嵌 plain-file）——本文件是仓库内
;;; 开发身份的唯一权威来源：身份字符串只出现在 gitconfig
;;; （tests/test-source-hygiene.scm 正向断言其精确形态——防扩散；
;;; AGENT.md §13 与 users/ 的 %primary-user 例外同理）。
;;;
;;; 跨 app 契约：.gitconfig include ~/.config/git/signing（由 gnupg
;;; app 贡献：user.signingkey + commit.gpgsign）。git app 依赖 gnupg
;;; app 启用——registry 打包启停；include 目标缺失时 git 报错
;;; （fail loud，不会静默弱签名）。

(define-module (guixcfg apps git definition)
               #:use-module (gnu packages version-control) ; git
               #:use-module (gnu home services)           ; home-files-service-type
               #:use-module (gnu services)                ; service
               #:use-module (guix gexp)                   ; local-file
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
              ,(local-file "gitconfig" "gitconfig"))))))))
