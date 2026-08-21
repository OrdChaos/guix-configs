;;; 会话级环境变量（Guix Home owns）：桌面会话范围内、跨应用的
;;; 用户偏好环境（输入法、Qt 平台主题、Electron/Proton Wayland
;;; 提示）。这些不是 compositor 行为——从 niri config 的
;;; environment 块迁出（docs/architecture/applications.md
;;; （Host-agnostic boundary）、graphics.md）。
;;;
;;; 机制：home-environment-variables-service-type 共享 sink 的
;;; native extension（与 apps/polkit-gnome 的 PATH 同款模式）——
;;; 变量经 Home setup-environment 进入会话环境，niri 及其 spawn
;;; 的进程自然继承。
;;;
;;; 已删除（由其它层正确管理，不在此重复声明）：
;;;   - FC_LANG "zh-cn"：system locale（%common-locale
;;;     "zh_CN.utf8"）已派生 fontconfig lang=zh-cn（fcdefault.c
;;;     FcGetDefaultLangs 顺序 FC_LANG > LC_ALL > LC_CTYPE > LANG）；
;;;     (guixcfg home fonts) 的策略显式依赖 locale 派生。
;;;   - XCURSOR_PATH：原配置硬编码 /home/<user> 与 /usr/share
;;;     FHS 路径（禁止迁移）；Guix Home setup-environment 已把
;;;     profile 的 share/icons 前置进 XCURSOR_PATH。cursor 主题
;;;     选择由 niri common.kdl 的 cursor {} 块声明；主题包本身
;;;     未入仓库（roadmap）。

(define-module (guixcfg home environment)
               #:use-module (gnu home services) ; home-environment-variables-service-type
               #:use-module (gnu services)      ; simple-service
               #:export (%session-environment-service))

;; 桌面会话环境变量（host-agnostic 用户偏好）。XMODIFIERS 指向
;; fcitx5，但 fcitx5 应用单元尚未入仓库（roadmap）——变量惰性无害，
;; 保留声明式事实。
(define %session-environment-service
  (simple-service 'session-environment
                  home-environment-variables-service-type
                  '(("XMODIFIERS" . "@im=fcitx")
                    ("QT_QPA_PLATFORMTHEME" . "gtk3")
                    ("ELECTRON_OZONE_PLATFORM_HINT" . "auto")
                    ("PROTON_ENABLE_WAYLAND" . "1"))))
