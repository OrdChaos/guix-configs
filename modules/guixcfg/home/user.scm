;;; Guix Home 入口（薄 assembly）：应用贡献全部来自显式 application
;;; registry（docs/architecture/home.md、AGENT.md §Application layer）；
;;; 用户级默认应用策略来自统一 XDG 模块（guixcfg home xdg）；字体
;;; 集合与 Fontconfig 策略来自 (guixcfg home fonts)；会话环境变量
;;; 来自 (guixcfg home environment)；仓库派生用户资源（avatar/
;;; wallpaper）来自 (guixcfg home assets)。本文件不知道 Git/Niri/
;;; Bash 等具体应用配置。
;;;
;;; host/profile 层只做 logical application configuration variant
;;; selection（(guixcfg apps selection)）——guix-home 接受
;;; #:application-configuration-selections 参数，由 generic resolver
;;; 解析为应用声明文件的安装；应用层不反向依赖 host。
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
               #:use-module (guixcfg apps selection) ; application-configuration-selections->home-services
               #:use-module (guixcfg home xdg)      ; %xdg-default-apps-service、%xdg-user-dirs-service
               #:use-module (guixcfg home fonts)    ; %fonts、%fontconfig-service、%home-fonts-xdg-link-service
               #:use-module (guixcfg home environment) ; %session-environment-service
               #:use-module (guixcfg home assets)   ; %user-assets-service
               #:use-module (guixcfg flatpak service) ; %flatpak-home-services（override 文件 + XDG_DATA_DIRS）
               #:use-module (guixcfg gsettings home-service) ; %gsettings-packages、%gsettings-reconcile-service
               #:export (guix-home
                         %guix-home))

(define* (guix-home #:key (application-configuration-selections '()))
         "构造 home-environment：registry 应用聚合 + 统一策略服务。
HOST/profile 的 application configuration variant selections 经
APPLICATION-CONFIGURATION-SELECTIONS（<application-configuration-
selection> 列表）贡献（generic mechanism，host 只做 logical
selection，不知道文件/路径）。"
         (home-environment
          (packages (append %fonts
                            %gsettings-packages   ; gsettings/dconf CLI（GSettings 投影机制自备 runtime 依赖）
                            (applications-home-packages %applications)))
          (services (append (list %xdg-default-apps-service
                                  %xdg-user-dirs-service
                                  %fontconfig-service
                                  %home-fonts-xdg-link-service
                                  %session-environment-service
                                  %user-assets-service
                                  %gsettings-reconcile-service) ; 登录/热激活后的 GSettings→dconf 投影 one-shot
                            ;; Flatpak 平台 Home 集成（override 完整文件
                            ;; 生成 + XDG_DATA_DIRS exports 追加；零
                            ;; flatpak CLI、零网络）。
                            %flatpak-home-services
                            (application-configuration-selections->home-services
                             application-configuration-selections)
                            (applications-home-services %applications)))))

;; 默认 home（host-agnostic）：VM 及其它无特殊 selection 的组装点
;; 直接使用；需要 variant 的组装点调用
;; (guix-home #:application-configuration-selections ...)。
(define %guix-home (guix-home))

;; 末尾裸表达式：guix home 的入口文件约定（取最后一个表达式）。
%guix-home
