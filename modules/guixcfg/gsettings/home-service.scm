;;; GSettings session reconcile service（docs/architecture/gsettings.md
;;; Projection lifecycle）：登录 / reconfigure 后把仓库聚合的 desired
;;; declarations 投影进 runtime dconf——机制通用层，不含具体 app
;;; 设置；aggregated declarations 在 build time 嵌入 wrapper
;;; （generation 变 → 新 store path → Home Shepherd 重跑 one-shot）。
;;;
;;; 生命周期接线（与既有 session 基础设施一致）：
;;;   Home Shepherd →（requirement '(dbus)）→ gsettings-reconcile
;;;   one-shot → PATH 解析 gsettings/dconf → validate（fail-loud）
;;;   → `dconf load /`。niri 之后、任何 GSettings 消费应用使用之前
;;;   （appearance-sync 走 xsettingsd-session 的既有触发，互不冲突：
;;;   appearance 6 键保留域由 ownership 校验强制，generic 层不可
;;;   声明）。
;;;
;;; 明确不放在普通 Home activation：activation 时 user D-Bus 未就绪，
;;; dconf 写入依赖 ca.desktop.dconf 服务——one-shot + dbus 依赖才是
;;; 正确接线。
;;;
;;; 运行前提（机制自备，不隐式耦合 apps/gtk）：glib:bin（gsettings
;;; CLI）与 dconf 由本模块的 %gsettings-packages 声明进 Home profile
;;; （home/user.scm 消费）；schema 集由各 application package 自带
;;; 的 share/glib-2.0/schemas 经 Home profile 统一 compiled。

(define-module (guixcfg gsettings home-service)
               #:use-module (gnu home services shepherd) ; home-shepherd-service-type
               #:use-module (gnu packages glib)          ; glib
               #:use-module (gnu packages gnome)         ; dconf
               #:use-module (gnu services)               ; simple-service
               #:use-module (gnu services shepherd)      ; shepherd-service
               #:use-module (guix gexp)                  ; program-file
               #:use-module (guix modules)               ; source-module-closure
               #:use-module (guixcfg apps registry)      ; %applications（唯一启用事实源）
               #:use-module (guixcfg apps model)         ; applications-gsettings
               #:use-module (guixcfg gsettings model)
               #:use-module (guixcfg gsettings reconcile)
               #:export (%gsettings-packages
                         %gsettings-reconcile-service))

;; 机制自备的 runtime 工具（gsettings / dconf CLI）；schema 由各
;; application package 经 Home profile 提供。
(define %gsettings-packages
  (list (list glib "bin") dconf))

;; ownership 校验 + desired state 在模块加载期完成（重复
;; (schema,key) / appearance 保留域冲突 → 构建期 fail-fast，
;; 不等到 login）。
(define %managed-gsettings
  (gsettings-desired-state (applications-gsettings %applications)))

;; gexp 可嵌入的 plain-list 视图（records 不直接序列化进 gexp；
;; wrapper 运行时重建 record）。
(define %managed-gsettings-entries
  (map (lambda (setting)
         (list (gsettings-setting-schema setting)
               (gsettings-setting-key setting)
               (gsettings-setting-value setting)))
       %managed-gsettings))

(define %gsettings-reconcile-wrapper
  (program-file
   "gsettings-reconcile"
   (with-imported-modules (source-module-closure
                           '((guixcfg gsettings model)
                             (guixcfg gsettings reconcile)
                             (guixcfg gsettings serialize)
                             (guixcfg utils process)
                             (guix build utils)))
                          #~(begin
                             (use-modules (guixcfg gsettings model)
                                          (guixcfg gsettings reconcile))
                             (let ((settings (map (lambda (entry)
                                                    (apply make-gsettings-setting entry))
                                                  '#$%managed-gsettings-entries)))
                               (format #t "gsettings reconcile: ~a managed key(s)~%"
                                       (length settings))
                               (for-each (lambda (line)
                                           (format #t "~a~%" line))
                                         (gsettings-status-format
                                          (gsettings-status settings)))
                               (gsettings-apply! settings)
                               (format #t "gsettings reconcile: done~%"))))))

;; one-shot Home Shepherd 服务：session D-Bus 就绪后把仓库声明的
;; GSettings 投影进 runtime dconf（desired 声明 build-time 嵌入；
;; Home generation 更新 → Shepherd 重跑本服务 → reconfigure 后立即
;; 生效，无需手工 `blue gsettings apply`）。
(define %gsettings-reconcile-service
  (simple-service
   'gsettings-reconcile
   home-shepherd-service-type
   (list (shepherd-service
          (documentation
           "Repository-derived GSettings projection: validate declared \
(schema,key,value) against the session schema set, then apply them \
via `dconf load /` (runtime dconf only; ~/.config/dconf is never \
persisted).")
          (provision '(gsettings-reconcile))
          (requirement '(dbus))          ; dconf 写入依赖 session D-Bus（ca.desktop.dconf）
          (one-shot? #t)
          (respawn? #f)
          (modules '((shepherd support))) ; %user-log-dir
          (start #~(make-forkexec-constructor
                    (list #$%gsettings-reconcile-wrapper)
                    #:log-file
                    (string-append %user-log-dir
                                   "/gsettings-reconcile.log")))
          (stop #~(make-kill-destructor))))))
