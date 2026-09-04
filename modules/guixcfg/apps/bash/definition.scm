;;; Bash application unit。所有权边界：System 拥有 /etc/passwd
;;; login shell；Home（本 app）拥有 shell rc、别名与环境变量。

(define-module (guixcfg apps bash definition)
               #:use-module (gnu services)                 ; service
               #:use-module (gnu home services shells)     ; home-bash-service-type
               #:use-module (guix gexp)                    ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%bash))

;; GPG/pinentry 的 tty 转发（2026-09 VM 实测根因）：gpg 客户端把
;; 自身环境里的 GPG_TTY 经 OPTION ttyname 传给 agent，agent 再传给
;; pinentry。Wayland-only 会话（无 DISPLAY，如 xwayland-satellite
;; 未激活时）pinentry-gtk-2 退回 curses 在终端里画密码框——没有
;; GPG_TTY 就无处可画，签名失败 "Inappropriate ioctl for device"。
;; tty 是 per-shell 动态事实，只能放 bashrc（每个交互 shell 求值），
;; 不能进 home-environment-variables 静态表。内容静态 → 独立文件
;; colocate（同目录 gpg-tty.bashrc）。
(define %bash-gpg-tty-bashrc
  (local-file "gpg-tty.bashrc" "bashrc-gpg-tty"))

(define %bash
  (application
   (name 'bash)
   (home-services
    (list (service home-bash-service-type
                   (home-bash-configuration
                    (environment-variables
                     '(("EDITOR" . "nano")
                       ("VISUAL" . "nano")
                       ("PAGER" . "less")))
                    (bashrc (list %bash-gpg-tty-bashrc))))))))
