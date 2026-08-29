;;; 声明式用户资源（user assets，Guix Home owns）：avatar / wallpaper
;;; 等仓库派生的二进制素材，安装到稳定 HOME 路径：
;;;   ~/.local/share/avatars/avatar.png
;;;   ~/.local/share/backgrounds/wallpaper.jpg
;;;
;;; 这些是 derived state（docs/architecture/home.md）：内容来自仓库
;;; assets/，经 (guixcfg utils repository-source) 的 repository-file
;;; 物化进 store（repo-root 相对素材的唯一 resolver，AGENT.md §12
;;; 禁止调用方散布跨层相对路径），home-files-service-type 投影为
;;; $HOME 下指向 Home generation closure 的链接：
;;;   - 不加入 persistence（只有 mutable state 才需要 backing）；
;;;   - 不在 activation 手工复制（activation 复制的是运行时可变
;;;     状态，这里由 symlink-manager 按 generation 重建）；
;;;   - 运行时修改不构成保存的状态：guix home reconfigure 按新
;;;     generation 重建链接，rollback 随 Home generation 回滚。
;;;
;;; 文件归属 service 选择（docs/development/applications.md 规则
;;; 反转）：与仓库全部 dotfile 同一通道——home-files-service-type
;;; + 显式 HOME 相对 target（.local/share/... 与 .config/、.ssh/
;;; 同构，不引入特化层）。
;;;
;;; 本模块只负责安装/暴露稳定路径；avatar/wallpaper 的消费者
;;; （greeter、AccountsService、niri 等）在各自模块引用路径常量，
;;; 不在本模块接线。

(define-module (guixcfg home assets)
               #:use-module (gnu home services) ; home-files-service-type
               #:use-module (gnu services)      ; simple-service
               #:use-module (guixcfg utils repository-source) ; repository-file
               #:export (%avatar-home-path
                         %wallpaper-home-path
                         %user-assets-service))

;; 稳定目标路径事实（HOME 相对）：消费者引用这些常量，不复制字符串。
(define %avatar-home-path ".local/share/avatars/avatar.png")
(define %wallpaper-home-path ".local/share/backgrounds/wallpaper.jpg")

;; 仓库派生资源投影：source 经 repository-file（repo-root 相对 →
;; store），target 为 HOME 相对路径（home-files 同一通道）。
(define %user-assets-service
  (simple-service 'user-assets
                  home-files-service-type
                  `((,%avatar-home-path ,(repository-file "assets/avatar.png"))
                    (,%wallpaper-home-path
                     ,(repository-file "assets/wallpaper.jpg")))))
