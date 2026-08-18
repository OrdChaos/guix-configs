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
               #:use-module (gnu home services desktop) ; home-dbus-service-type
               #:use-module (gnu home services niri)    ; home-niri-service-type
               #:use-module (gnu home services sound)   ; home-pipewire-service-type
               #:use-module (guix gexp)
               #:use-module (guix records)
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
                   "[init]\n\tdefaultBranch = main\n"))))
     ;; M2：官方 Home 用户桌面生命周期（docs/architecture/
     ;; upstream-boundaries.md——capability owner 回归 pinned Guix）：
     ;;   单 user session D-Bus（home-dbus-service-type）
     ;;   niri 用户生命周期（home-niri-service-type：bash -l -c
     ;;     "exec niri --session"；profile 自动贡献 dbus/niri/
     ;;     xdg-desktop-portal-* / xwayland-satellite；requirement dbus）
     ;;   PipeWire + WirePlumber（home-pipewire-service-type）
     (service home-dbus-service-type)
     (service home-niri-service-type)
     (service home-pipewire-service-type)
     ;; niri 配置：XDG 官方 mechanism（home-xdg-configuration-files-
     ;; service-type——声明式 derived state，每次 fresh root/Home
     ;; activation 恢复；不持久化、app 不是第二 authority）。
     (service home-xdg-configuration-files-service-type
              `(("niri/config.kdl"
                 ,(local-file "../../../files/niri/config.kdl"
                              "niri-config.kdl"))))))))

;; 末尾裸表达式：guix home 的入口文件约定（取最后一个表达式）。
%guix-home
