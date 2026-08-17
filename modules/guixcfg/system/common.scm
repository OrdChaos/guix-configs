;;; 系统公共部分：所有 host 共享的基础设置。
;;; 对应 docs/architecture/overview.md（host 是组装点，共享内容放这里）。

(define-module (guixcfg system common)
               #:use-module (gnu services)         ; service
               #:use-module (gnu services desktop) ; elogind-service-type
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
(define %common-services
  (list (service elogind-service-type)))
