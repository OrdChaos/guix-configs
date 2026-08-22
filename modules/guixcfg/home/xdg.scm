;;; 统一 XDG / default-applications 策略（Guix Home owns）：用户级
;;; 默认应用选择——MIME associations、URL scheme handlers、默认
;;; 浏览器、默认 PDF/图片查看器等；以及 XDG user directories 声明。
;;; 应用模块只描述应用本身；“是否被选作默认”由本模块决定
;;; （AGENT.md §Application layer、docs/architecture/applications.md）。
;;;
;;; 机制：官方 home-xdg-mime-applications-service-type 声明式生成
;;; $XDG_CONFIG_HOME/mimeapps.list 的 [Default Applications]
;;; （derived state，随 Home generation 重建；不进 application
;;; persistence）。desktop entry 事实来自应用模块的纯数据常量
;;; （如 %chrome-desktop-entry）——本模块不复制应用专属字符串；
;;; 依赖方向 policy → app metadata，无循环。
;;;
;;; 变更默认应用只改本文件（增删 association / 换默认浏览器）。

(define-module (guixcfg home xdg)
               #:use-module (gnu home services xdg)  ; home-xdg-mime-applications-*、home-xdg-user-directories-service-type
               #:use-module (gnu services)           ; simple-service、service
               #:use-module (guixcfg apps google-chrome-stable definition)
               #:export (%xdg-default-apps-service
                         %xdg-user-dirs-service))

;; 默认浏览器：Google Chrome（stable）。desktop entry 来自 Chrome
;; 模块的纯数据常量；选择策略在这里——默认 HTML 与 http/https
;; scheme 都指向 Chrome。
(define %xdg-default-applications
  (map (lambda (mime)
         (cons mime (list %chrome-desktop-entry)))
       '("text/html"
         "application/xhtml+xml"
         "x-scheme-handler/http"
         "x-scheme-handler/https")))

(define %xdg-default-apps-service
  (simple-service 'xdg-default-apps
                  home-xdg-mime-applications-service-type
                  (home-xdg-mime-applications-configuration
                   (default %xdg-default-applications))))

;; ── XDG user directories ──────────────────────────────────────
;; 官方 home-xdg-user-directories-service-type（pinned
;; gnu/home/services/xdg.scm）：生成 $XDG_CONFIG_HOME/user-dirs.dirs
;; （GTK 等经 xdg-user-dir 查询目录位置）+ activation 创建各目录
;; （$HOME/<Name>；user-dirs.conf enabled=False 防止 xdg-user-dirs-
;; update 改写）。default value 即标准 XDG 全集（Desktop/
;; Documents/Downloads/Music/Pictures/Projects/Public/Templates/
;; Videos）——显式声明意图，目录位置与持久化 backing 的对应由
;; (guixcfg system user-persistence) 的 %persistent-user-dirs 提供
;; （两处一致性由 tests/test-user-persistence.scm 回归）。
(define %xdg-user-dirs-service
  (service home-xdg-user-directories-service-type))
