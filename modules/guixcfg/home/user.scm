;;; Guix Home 入口（薄 assembly）：应用贡献全部来自显式 application
;;; registry（docs/architecture/home.md、AGENT.md §Application layer）；
;;; 用户级默认应用策略来自统一 XDG 模块（guixcfg home xdg）；字体
;;; 集合与 Fontconfig 策略来自 (guixcfg home fonts)。本文件不知道
;;; Git/Niri/Bash 等具体应用配置。
;;;
;;;   registry（%applications）          (guixcfg home xdg)   (guixcfg home fonts)
;;;      ↓ aggregation                    ↓ 默认应用策略        ↓ %fonts + fontconfig
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
               #:use-module (guixcfg home xdg)      ; %xdg-default-apps-service
               #:use-module (guixcfg home fonts)    ; %fonts、%fontconfig-service
               #:export (%guix-home))

(define %guix-home
  (home-environment
   (packages (append %fonts
                     (applications-home-packages %applications)))
   (services (append (list %xdg-default-apps-service
                           %fontconfig-service)
                     (applications-home-services %applications)))))

;; 末尾裸表达式：guix home 的入口文件约定（取最后一个表达式）。
%guix-home
