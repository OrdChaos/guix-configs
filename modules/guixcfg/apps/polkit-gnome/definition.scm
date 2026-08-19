;;; polkit-gnome application unit：graphical polkit authentication
;;; agent（niri spawn-at-startup）。consumer 名 = polkit-gnome。
;;;
;;; 二进制位于 libexec（pinned 0.105 src/Makefile.am：
;;; libexec_PROGRAMS = polkit-gnome-authentication-agent-1）——不在
;;; PATH、也没有 FHS 的 /usr/lib/polkit-gnome 路径。因此：
;;;   - home-files 提供 ~/.local/bin/polkit-gnome-authentication-agent-1
;;;     wrapper（program-file，guix 构建期注入 store 绝对路径——
;;;     仓库不硬编码 store 路径字面量）；
;;;   - PATH 增加 ~/.local/bin（session 基础设施 env contribution）；
;;;   - niri config.kdl 用稳定名 spawn
;;;     （spawn-at-startup "polkit-gnome-authentication-agent-1"）。
;;;
;;; 边界与 lxpolkit 相同：agent 属于 graphical session；polkitd 属于
;;; system（%common-services 的 polkit-service-type）；无 persistence、
;;; 无 declarative secrets、不拥有 system D-Bus。

(define-module (guixcfg apps polkit-gnome definition)
               #:use-module (gnu packages polkit) ; polkit-gnome
               #:use-module (gnu home services)   ; home-files-service-type
               #:use-module (gnu services)        ; service
               #:use-module (guix gexp)           ; program-file、file-append
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%polkit-gnome))

(define %polkit-gnome
  (application
   (name 'polkit-gnome)
   (home-packages (list polkit-gnome))
   (home-services
    (list (simple-service
           'polkit-gnome-agent-wrapper
           home-files-service-type
           `((".local/bin/polkit-gnome-authentication-agent-1"
              ,(program-file
                "polkit-gnome-authentication-agent-1"
                #~(execl #$(file-append polkit-gnome
                                        "/libexec/polkit-gnome-authentication-agent-1")
                         "polkit-gnome-authentication-agent-1")))))
          ;; wrapper 可解析所需：~/.local/bin 进 session PATH
          ;; （home-environment-variables 共享 sink 的 native extension）。
          (simple-service
           'polkit-gnome-path
           home-environment-variables-service-type
           '(("PATH" . "$HOME/.local/bin:$PATH")))))))
