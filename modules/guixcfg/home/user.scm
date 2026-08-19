;;; Guix Home 入口（薄 assembly）：应用贡献全部来自显式 application
;;; registry（docs/architecture/home.md、AGENT.md §Application layer）。
;;; 本文件不知道 Git/Niri/Bash 等具体应用配置。
;;;
;;;   registry（%applications）
;;;      ↓ applications-home-packages / applications-home-services
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
               #:export (%guix-home))

(define %guix-home
  (home-environment
   (packages (applications-home-packages %applications))
   (services (applications-home-services %applications))))

;; 末尾裸表达式：guix home 的入口文件约定（取最后一个表达式）。
%guix-home
