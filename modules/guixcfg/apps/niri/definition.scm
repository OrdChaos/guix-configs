;;; niri application unit：用户桌面生命周期（home-niri-service-type，
;;; bash -l -c "exec niri --session"；profile 自动贡献 dbus/niri/
;;; xdg-desktop-portal-*/xwayland-satellite；requirement home-dbus）
;;; + niri 公开配置（config.kdl，本目录 colocate）。
;;;
;;; config.kdl 经官方 home-xdg-configuration-files-service-type 以
;;; source-relative local-file 声明（pinned Guix local-file 宏按
;;; 出现处 source directory 解析）——derived state，每次 fresh
;;; root/Home activation 恢复；不持久化、app 不是第二 authority。

(define-module (guixcfg apps niri definition)
               #:use-module (gnu home services)      ; home-xdg-configuration-files-service-type
               #:use-module (gnu home services niri) ; home-niri-service-type
               #:use-module (gnu services)           ; service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%niri))

(define %niri
  (application
   (name 'niri)
   (home-services
    (list (service home-niri-service-type)
          (service home-xdg-configuration-files-service-type
                   `(("niri/config.kdl"
                      ,(local-file "config.kdl" "niri-config.kdl"))))))))
