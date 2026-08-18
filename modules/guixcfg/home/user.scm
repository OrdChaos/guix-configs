;;; Minimal Guix Home 入口（第一版只证明 Home 可 build/reconfigure、
;;; generation 独立、CLI 环境声明式）。
;;;
;;; 所有权边界：System 拥有 sshd/机器用户/持久化挂载/login shell；
;;; Home 拥有用户包、shell rc、Git config、环境变量。Home 不挂载
;;; /persist、不管 sshd、不创建私钥。
;;;
;;; 用法（普通用户，不需要 sudo）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     home reconfigure -L modules modules/guixcfg/home/user.scm

(define-module (guixcfg home user)
               #:use-module (gnu home)
               #:use-module (gnu home services)
               #:use-module (gnu home services shells)  ; home-bash-service-type
               #:use-module (guix gexp)
               #:use-module (guixcfg home packages)
               #:export (%guix-home))

(define %guix-home
  (home-environment
   (packages %home-packages)
   (services
    (list
     ;; Bash（System 拥有 /etc/passwd login shell；Home 拥有 shell rc、
     ;; 别名与环境变量）。
     (service home-bash-service-type
              (home-bash-configuration
               (environment-variables
                '(("EDITOR" . "nano")
                  ("VISUAL" . "nano")
                  ("PAGER" . "less")))))
     ;; Git：纯行为设置（不猜 user.name/email——个人身份留待以后）。
     (service home-files-service-type
              `((".gitconfig"
                 ,(plain-file
                   "gitconfig"
                   "[init]\n\tdefaultBranch = main\n"))
                ;; M2：niri 配置（declarative derived state——
                ;; ~/.config/niri/config.kdl 由 Home 生成，每次 fresh
                ;; root/Home activation 恢复，不持久化、app 不是第二
                ;; authority；docs/architecture/graphics.md）。
                (".config/niri/config.kdl"
                 ,(local-file "../../../files/niri/config.kdl"
                              "niri-config.kdl"))))))))

;; 末尾裸表达式：guix home 的入口文件约定（取最后一个表达式）。
%guix-home
