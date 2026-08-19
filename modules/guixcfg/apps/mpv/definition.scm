;;; mpv application unit——第一个真实 production
;;; application-persistence consumer（docs/architecture/persistence.md；
;;; 教程见 docs/development/applications.md）。
;;;
;;; 设计（pinned mpv 0.41.0 审计）：
;;;   - 配置：~/.config/mpv/{mpv.conf,input.conf}（XDG_CONFIG_HOME；
;;;     repo/Home authority，source-relative local-file colocate）；
;;;   - mutable state：~/.local/state/mpv/（XDG_STATE_HOME；
;;;     watch-later 默认 ~/.local/state/mpv/watch_later，
;;;     DOCS/man/options.rst）——application authority；
;;;   - 因此 declarative config 与 mutable state 天然分离
;;;     （decision tree 的 Preferred 1）——只持久化 state 目录，
;;;     不需要 mixed container；
;;;   - save-position-on-quit=yes 启用 watch-later（resume）。
;;;
;;; 不持久化 .config/mpv（declarative，随 generation 重建）；
;;; 不持久化整个 .local/state（公共 root 禁止整体持久化）。

(define-module (guixcfg apps mpv definition)
               #:use-module (gnu packages video)      ; mpv
               #:use-module (gnu home services)      ; home-xdg-configuration-files-service-type
               #:use-module (gnu services)           ; service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%mpv))

(define %mpv
  (application
   (name 'mpv)
   (home-packages (list mpv))
   (home-services
    (list (simple-service 'mpv-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("mpv/mpv.conf" ,(local-file "mpv.conf" "mpv-mpv.conf"))
                            ("mpv/input.conf" ,(local-file "input.conf" "mpv-input.conf"))))))
   (persistence
    (list (application-persistence-rule
           (name 'state)
           (backing "mpv/state")          ; backing root 相对（persistence.md）
           (consumer ".local/state/mpv")  ; HOME 相对（app-private state dir）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
