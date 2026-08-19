;;; 系统公共部分：所有 host 共享的基础设置。
;;; 对应 docs/architecture/overview.md（host 是组装点，共享内容放这里）。

(define-module (guixcfg system common)
               #:use-module (gnu services)         ; service
               #:use-module (gnu services desktop) ; elogind-service-type、polkit-wheel-service
               #:use-module (gnu services dbus)    ; polkit-service-type（polkitd 的 authority）
               #:use-module (guixcfg system substitutes) ; nonguix-substitute-service
               #:export (%common-timezone
                         %common-locale
                         %common-services))

;; 时区与区域设置：两台机器相同。
(define %common-timezone "Asia/Shanghai")

;; VM 阶段先用 en_US.utf8（locale 数据小、验证简单）；
;; 桌面阶段（阶段 7）再按需要加 zh_CN.utf8 等 locale 定义。
(define %common-locale "en_US.utf8")

;; 基础 session infrastructure（docs/architecture/accounts-sessions.md J6）：
;; elogind 提供 login/session tracking、/run/user/<uid> 生命周期与
;; XDG_RUNTIME_DIR。它是系统层职责——Home/persistence 都不碰 runtime
;; 目录。所有 host（VM: sshd+elogind；未来 desktop: greetd+elogind）
;; 共享这一层；%base-services 不含 elogind，这里显式补充。
;;
;; Nonguix substitute trust（docs/architecture/overview.md（Nonguix
;; integration））：guix-daemon 的 additive extension——官方 Guix
;; substitutes 保留，追加 official Nonguix substitute URL + signing
;; key。所有 host 共享同一 policy（不 per-host 重复）。
;; 桌面认证基础设施（docs/architecture/desktop-authentication.md）：
;; polkit 是 system authority（polkitd 经 system D-Bus activation 启动，
;; 无 shepherd 服务）。elogind 已经经其 service extension 隐式物化
;; polkit（instantiate-missing-services），这里在 authority 层显式
;; 声明，并加上 upstream admin identity（polkit-wheel-service =
;; addAdminRule unix-group:wheel——admin 身份声明，不是 blanket
;; allow）。graphical authentication agent（lxpolkit）属于用户会话
;; （apps/lxpolkit，niri spawn-at-startup）——不在这里。
(define %common-services
  (list (service elogind-service-type)
        (service polkit-service-type)
        polkit-wheel-service
        nonguix-substitute-service))
