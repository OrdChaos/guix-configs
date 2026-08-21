;;; Guix Home 入口（薄 assembly）：应用贡献全部来自显式 application
;;; registry（docs/architecture/home.md、AGENT.md §Application layer）；
;;; 用户级默认应用策略来自统一 XDG 模块（guixcfg home xdg）；字体
;;; 集合与 Fontconfig 策略来自 (guixcfg home fonts)；会话环境变量
;;; 来自 (guixcfg home environment)。本文件不知道 Git/Niri/Bash 等
;;; 具体应用配置。
;;;
;;; host/profile 层可经 generic extra-configuration-files 机制
;;; （(guixcfg apps extra-config)）向应用配置目录额外贡献原生配置
;;; 文件（如 laptop 的 niri/host.kdl）——guix-home 接受
;;; #:extra-configuration-files 参数；应用层不反向依赖 host。
;;;
;;;   registry（%applications）    (guixcfg home xdg)   (guixcfg home fonts)
;;;      ↓ aggregation               ↓ 默认应用策略      ↓ %fonts + fontconfig
;;;   home-environment（%guix-home）
;;;
;;; System+Home generation 绑定不变：%guix-home 经 guix-home-service-
;;; type 嵌入 system generation（hosts/vm.scm），boot 时官方 Home
;;; activation 重建 ephemeral HOME——runtime 不依赖配置 repository。
;;;
;;; 用法（普通用户，不需要 sudo）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     home reconfigure -L modules modules/guixcfg/home/user.scm

(define-module (guixcfg home user)
               #:use-module (gnu home)              ; home-environment
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg apps registry)
               #:use-module (guixcfg apps extra-config) ; extra-configuration-files->home-services
               #:use-module (guixcfg home xdg)      ; %xdg-default-apps-service
               #:use-module (guixcfg home fonts)    ; %fonts、%fontconfig-service
               #:use-module (guixcfg home environment) ; %session-environment-service
               #:export (guix-home
                         %guix-home))

(define* (guix-home #:key (extra-configuration-files '()))
         "构造 home-environment：registry 应用聚合 + 统一策略服务。
HOST/profile 的额外应用配置文件经 EXTRA-CONFIGURATION-FILES
（<extra-configuration-file> 列表）贡献（generic mechanism，
host-agnostic）。"
         (home-environment
          (packages (append %fonts
                            (applications-home-packages %applications)))
          (services (append (list %xdg-default-apps-service
                                  %fontconfig-service
                                  %session-environment-service)
                            (extra-configuration-files->home-services
                             extra-configuration-files)
                            (applications-home-services %applications)))))

;; 默认 home（host-agnostic）：VM 及其它无 host-specific 贡献的
;; 组装点直接使用；需要 host 额外配置的组装点调用
;; (guix-home #:extra-configuration-files ...)。
(define %guix-home (guix-home))

;; 末尾裸表达式：guix home 的入口文件约定（取最后一个表达式）。
%guix-home
