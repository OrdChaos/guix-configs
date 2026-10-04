;;; 系统公共部分：所有 host 共享的基础设置。
;;; 对应 docs/architecture/overview.md（host 是组装点，共享内容放这里）。

(define-module (guixcfg system common)
  #:use-module (gnu services) ;service
  #:use-module (gnu services base) ;guix-service-type、guix-configuration
  #:use-module (gnu services desktop) ;elogind-service-type、elogind-configuration、polkit-wheel-service
  #:use-module (gnu services dbus) ;polkit-service-type（polkitd 的 authority）
  #:use-module (guix gexp) ;local-file
  #:use-module (virelith packages elogind) ;elogind-compat（257.16）
  #:export (%common-timezone %common-locale %common-services))

;; 时区与区域设置：两台机器相同。
(define %common-timezone
  "Asia/Shanghai")

;; 中文 locale（桌面阶段）：zh_CN.utf8 已在 pinned guix
;; %default-locale-definitions 内（gnu/system/locale.scm 的
;; utf8-locales 列表含 "zh_CN"），且 (locale ...) 字段指定的 locale
;; 会自动加入 locale-directory 构建——零额外依赖。
;; 会话 LANG=zh_CN.utf8 → Fontconfig 默认 lang=zh-cn（fcdefault.c
;; FcGetDefaultLangs：FC_LANG > LC_ALL > LC_CTYPE > LANG），强化
;; 字体配置的 SC-first 语义（(guixcfg home fonts) 已核实，无破坏）。
(define %common-locale
  "zh_CN.utf8")

;; 基础 session infrastructure（docs/architecture/accounts-sessions.md）：
;; elogind 提供 login/session tracking、/run/user/<uid> 生命周期与
;; XDG_RUNTIME_DIR。它是系统层职责——Home/persistence 都不碰 runtime
;; 目录。所有 host 共享这一层；%base-services 不含 elogind，这里显式补充。
;;
;; elogind 来自 virelith channel 的 elogind-compat（257.16）：
;; pinned Guix master 的 elogind 停留在 255.22；virelith 继承官方
;; elogind 的依赖与构建逻辑，只覆盖 source（version/tag 前缀/commit/
;; hash），ABI 向后兼容（SONAME libelogind.so.0 不变）。channel 源在
;; reconfigure / tests/run-tests.scm 时已加入 load path，直接 import
;; (virelith packages elogind) 即可（elogind-service-type 各 extension
;; 消费 elogind-configuration 的 elogind 字段，无需其他改动）。
;; 注意：257 系列 D-Bus activation 仍走 shepherd wrapper（elogind 的
;; org.freedesktop.login1.service Exec 由 elogind-dbus-service 替换为
;; shepherd-sync）——拆除 wrapper 属第二步（另行确认后执行）。
;;
;; 桌面认证基础设施（docs/architecture/desktop-authentication.md）：
;; polkit 是 system authority（polkitd 经 system D-Bus activation 启动，
;; 无 shepherd 服务）。elogind 已经经其 service extension 隐式物化
;; polkit（instantiate-missing-services），这里在 authority 层显式
;; 声明，并加上 upstream admin identity（polkit-wheel-service =
;; addAdminRule unix-group:wheel——admin 身份声明，不是 blanket
;; allow）。graphical authentication agent（polkit-gnome）属于用户会话
;; （apps/polkit-gnome，niri spawn-at-startup + ~/.local/bin wrapper）
;; ——不在这里。
;;
;; Substitute policy（所有 host 共享，不 per-host 重复）：
;;   substitute-urls 显式全列（镜像优先，官方兜底；显式列表而非
;;   guix-extension 追加，因为顺序即优先级）：
;;   - mirror.sjtu.edu.cn/guix：SJTU 镜像，官方 berlin 签名 narinfo
;;     的纯镜像（实测 2026-10-04），免新密钥；
;;   - cache-cdn.guix.moe：guix.moe 农场的镜像——narinfo 由源站直出、
;;     nar 经 nars.guix.moe（Cloudflare anycast，与代理出口区域无关）；
;;   - 官方 ci/bordeaux 兜底主线内容；
;;   - substitutes.nonguix.org：nonguix 包（linux-7.2/firmware/
;;     microcode）的 substitute 源，同时是 guix.moe 农场的源站
;;     （2026-08-23 nonguix.org 与 guix.moe 基础设施合并，见
;;     guix-devel 2026-08-07 公告）；置于末尾——nonguix 内容已由
;;     cache-cdn 镜像承载，它是 origin 兜底。
;;   nonguix 签名 key 经同目录 nonguix-key.pub 授权（内容与
;;   https://substitutes.nonguix.org/signing-key.pub 逐字节一致）。
;;   沿革：2026-08-25 曾移除第三方 substitute（当时
;;   substitutes.nonguix.org 无镜像、可靠性存疑）；2026-10-04 随
;;   guix.moe 合并运营 + 镜像体系可用而恢复，实测本地编译的
;;   linux-7.2.7 在其上已有对应 narinfo（nuporta 签名）。
;; 本地编译空间：显式声明 guix-daemon TMPDIR=/var/tmp（pinned
;; guix-configuration 的 tmpdir 字段 → shepherd 服务环境 TMPDIR=；
;; 默认 /tmp 是 7.7GB tmpfs，装不下内核编译的 ~11GB 中间产物——
;; 2026-08-25 实测 -j8/-j2 均 ENOSPC）。主机（Arch systemd daemon）
;; 由 /etc/systemd/system/guix-daemon.service 的 Environment 单独配置。
(define %common-services
  (list (service guix-service-type
                 (guix-configuration (tmpdir "/var/tmp")
                                     (substitute-urls '("https://mirror.sjtu.edu.cn/guix"
                                                        "https://cache-cdn.guix.moe"
                                                        "https://ci.guix.gnu.org"
                                                        "https://bordeaux.guix.gnu.org"
                                                        "https://substitutes.nonguix.org"))
                                     (authorized-keys (list (local-file
                                                             "nonguix-key.pub")))))
        (service elogind-service-type
                 (elogind-configuration (elogind elogind-compat)))
        (service polkit-service-type) polkit-wheel-service))
