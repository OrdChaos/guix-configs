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
               #:use-module (guix gexp)                  ; program-file、file-append
               #:use-module (guixcfg apps registry)      ; %applications（唯一启用事实源）
               #:use-module (guixcfg apps model)         ; applications-gsettings
               #:use-module (guixcfg gsettings model)
               #:use-module (guixcfg gsettings serialize)
               #:use-module (guixcfg users user)         ; %primary-user、user-profile-home-directory
               #:export (%gsettings-packages
                         %gsettings-reconcile-service
                         %gsettings-reconcile-wrapper))

;; 机制自备的 runtime 工具（gsettings / dconf CLI）；schema 由各
;; application package 经 Home profile 提供。
(define %gsettings-packages
  (list (list glib "bin") dconf))

;; ownership 校验 + desired state 在模块加载期完成（重复
;; (schema,key) / appearance 保留域冲突 → 构建期 fail-fast，
;; 不等到 login）。
(define %managed-gsettings
  (gsettings-desired-state (applications-gsettings %applications)))

;; gexp 可嵌入的 plain-list 视图（records 不直接序列化进 gexp）。
(define %managed-gsettings-entries
  (map (lambda (setting)
         (list (gsettings-setting-schema setting)
               (gsettings-setting-key setting)
               (gsettings-setting-value setting)))
       %managed-gsettings))

;; 序列化在构建期完成（keyfile 文本直接嵌入 gexp）。
(define %gsettings-keyfile
  (serialize-gsettings-keyfile %managed-gsettings))

;; wrapper 实现约束（仓库既有惯例，ssh/gnupg session wrapper 同款）：
;;   - 只用 core guile + ice-9（guile 自带模块树，任何 guile 进程
;;     都能解析）——【绝不】import 仓库/guix 模块：home derivation
;;     在 daemon 侧 lowering 时 %load-path 只有 channel 源，没有
;;     仓库 modules/，gexp 模块闭包拿不到 (guixcfg …)（VM 实测：
;;     闭包只剩 guix/，运行时 no code for module）；
;;   - 二进制经 file-append 绝对 store 路径嵌入（shepherd 环境
;;     PATH 不可靠，绝不 PATH 解析）；
;;   - dconf load 走 stdin（文本 keyfile，不落盘）；
;;   - schema 校验（list-keys / key 存在性）fail-loud；值合法性由
;;     dconf load 自身接受性兜底（与 reconcile 层一致）。
(define %gsettings-reconcile-wrapper
  (program-file
   "gsettings-reconcile"
   #~(begin
      (use-modules (ice-9 popen)      ; open-pipe*
                   (ice-9 rdelim)     ; read-string
                   (ice-9 string-fun) ; string-tokenize
                   (ice-9 match)
                   (srfi srfi-1))     ; member
      (define gsettings-bin #$(file-append (gexp-input glib "bin") "/bin/gsettings"))
      (define dconf-bin #$(file-append dconf "/bin/dconf"))
      (define entries '#$%managed-gsettings-entries)
      (define keyfile #$%gsettings-keyfile)
      (define home (or (getenv "HOME")
                       #$(user-profile-home-directory %primary-user)))

      ;; 会话 schema 集：优先会话环境，缺失时回退 Home profile
      ;; 的标准 compiled schemas 位置。
      (define schemas-dir
        (or (getenv "GSETTINGS_SCHEMA_DIR")
            (string-append home
                           "/.guix-home/profile/share/glib-2.0/schemas")))
      (setenv "GSETTINGS_SCHEMA_DIR" schemas-dir)

      (define (capture args)
        (let* ((port (apply open-pipe* OPEN_READ args))
               (out (read-string port))
               (status (close-pipe port)))
          (values out (status:exit-val status))))

      (define (schema-keys schema)
        (call-with-values
            (lambda () (capture (list gsettings-bin "list-keys" schema)))
          (lambda (out status)
            (and (zero? status)
                 (string-tokenize out)))))

      (format #t "gsettings reconcile: ~a managed key(s)~%" (length entries))
      ;; validate：schema 缺失 / key 缺失 fail-loud（one-shot 失败
      ;; 由 shepherd 记录，绝不 silent ignore）。
      (for-each (lambda (entry)
                  (match entry
                    ((schema key _)
                     (let ((keys (schema-keys schema)))
                       (cond
                        ((not keys)
                         (format (current-error-port)
                                 "gsettings reconcile: schema not found: ~a~%"
                                 schema)
                         (exit 1))
                        ((not (member key keys))
                         (format (current-error-port)
                                 "gsettings reconcile: key not found: ~a / ~a~%"
                                 schema key)
                         (exit 1)))))))
                entries)
      ;; dconf load /（stdin；唯一 mutation，绝不 reset 全库）
      (unless (string-null? keyfile)
        (let ((port (open-pipe* OPEN_WRITE dconf-bin "load" "/")))
          (display keyfile port)
          (let ((status (status:exit-val (close-pipe port))))
            (unless (zero? status)
              (format (current-error-port)
                      "gsettings reconcile: dconf load failed (exit ~a)~%"
                      status)
              (exit 1)))))
      (format #t "gsettings reconcile: done~%"))))

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
