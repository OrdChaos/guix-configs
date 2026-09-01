;;; GSettings session reconcile service（docs/architecture/gsettings.md
;;; Projection lifecycle）：登录 / reconfigure 后把仓库聚合的 desired
;;; declarations 投影进 runtime dconf——机制通用层，不含具体 app
;;; 设置、不含 application registry、不含 user inventory。
;;;
;;; Composition 边界（本模块不读任何全局 inventory）：
;;;   desired settings 与 HOME 事实由 composition 层（(guixcfg home
;;;   user)）从 application registry / (guixcfg users user) 聚合后
;;;   显式传入：
;;;
;;;     (gsettings-reconcile-service
;;;      (gsettings-desired-state (applications-gsettings %applications))
;;;      (user-profile-home-directory %primary-user))
;;;
;;;   desired 声明在 build time 嵌入 wrapper（generation 变 → 新
;;;   store path → Home Shepherd 重跑 one-shot）。
;;;
;;; 生命周期接线（与既有 session 基础设施一致）：
;;;   Home Shepherd →（requirement '(dbus)）→ gsettings-reconcile
;;;   one-shot → 运行唯一 runtime contract（runtime.scm）→ validate
;;;   （fail-loud）→ `dconf load /`。appearance-sync 走
;;;   xsettingsd-session 的既有触发，互不冲突（appearance 6 键保留域
;;;   由 ownership 校验强制）。
;;;
;;; 明确不放在普通 Home activation：activation 时 user D-Bus 未就绪，
;;; dconf 写入依赖 ca.desktop.dconf 服务——one-shot + dbus 依赖才是
;;; 正确接线。
;;;
;;; wrapper 实现约束（仓库既有惯例，ssh/gnupg session wrapper 同款）：
;;;   - 只用 core guile + ice-9（guile 自带模块树，任何 guile 进程
;;;     都能解析）——【绝不】import 仓库/guix 模块：home derivation
;;;     在 daemon 侧 lowering 时 %load-path 只有 channel 源，没有
;;;     仓库 modules/，gexp 模块闭包拿不到 (guixcfg …)（VM 实测：
;;;     闭包只剩 guix/，运行时 no code for module）。runtime contract
;;;     经 (local-file "runtime.scm") 按值嵌入 + (load ...)；
;;;   - 二进制经 file-append（gexp-input 指定 output）绝对 store
;;;     路径嵌入（shepherd 环境 PATH 不可靠，绝不 PATH 解析）；
;;;   - dconf load 走 stdin（文本 keyfile，不落盘）；
;;;   - 校验与错误分类与 manual 路径共享同一 runtime contract
;;;     （含 invalid-desired-value 浅层校验——两条链语义一致）。
;;;
;;; 运行前提（机制自备，不隐式耦合 apps/gtk）：glib:bin（gsettings
;;; CLI）与 dconf 由 %gsettings-packages 声明进 Home profile
;;; （(guixcfg home user) 消费）；schema 集由各 application package
;;; 自带的 share/glib-2.0/schemas 经 Home profile 统一 compiled。

(define-module (guixcfg gsettings home-service)
               #:use-module (gnu home services shepherd) ; home-shepherd-service-type
               #:use-module (gnu packages glib)          ; glib
               #:use-module (gnu packages gnome)         ; dconf
               #:use-module (gnu services)               ; simple-service
               #:use-module (gnu services shepherd)      ; shepherd-service
               #:use-module (guix gexp)                  ; program-file、file-append、local-file、gexp-input
               #:use-module (guixcfg gsettings model)
               #:use-module (guixcfg gsettings serialize)
               #:export (%gsettings-packages
                         gsettings-reconcile-service
                         gsettings-reconcile-wrapper))

;; 机制自备的 runtime 工具（gsettings / dconf CLI）；schema 由各
;; application package 经 Home profile 提供。
(define %gsettings-packages
  (list (list glib "bin") dconf))

;; 唯一 runtime contract 源文件（与 reconcile.scm 的
;; include-from-path 是同一份源码；wrapper 经 local-file 嵌入 +
;; load——见文件头）。
(define %gsettings-runtime-source
  (local-file "runtime.scm" "gsettings-runtime"))

(define* (gsettings-reconcile-wrapper desired-settings home-directory)
  "DESIRED-SETTINGS（<gsettings-setting> 列表，须已通过
gsettings-desired-state 的 ownership 校验与排序）→ generated
program-file（core-guile + runtime contract）。HOME-DIRECTORY 是
HOME 的权威路径（GSETTINGS_SCHEMA_DIR 回退与 HOME 环境回退）。"
  (let* ((entries
          (map (lambda (setting)
                 (list (gsettings-setting-schema setting)
                       (gsettings-setting-key setting)
                       (gsettings-setting-value setting)))
               desired-settings))
         (keyfile (serialize-gsettings-keyfile desired-settings)))
    (program-file
     "gsettings-reconcile"
     #~(begin
        (use-modules (ice-9 match))
        ;; 唯一 runtime contract（校验/五态/dconf load 与 manual
        ;; 路径同一份实现）。
        (load #$%gsettings-runtime-source)
        (define gsettings-bin #$(file-append (gexp-input glib "bin") "/bin/gsettings"))
        (define dconf-bin #$(file-append dconf "/bin/dconf"))
        (define entries '#$entries)
        (define keyfile #$keyfile)
        (define home (or (getenv "HOME") #$home-directory))

        ;; 会话 schema 集：优先会话环境，缺失时回退 Home profile
        ;; 的标准 compiled schemas 位置。
        (define schemas-dir
          (or (getenv "GSETTINGS_SCHEMA_DIR")
              (string-append home
                             "/.guix-home/profile/share/glib-2.0/schemas")))
        (setenv "GSETTINGS_SCHEMA_DIR" schemas-dir)

        (format #t "gsettings reconcile: ~a managed key(s)~%" (length entries))
        (for-each (lambda (line)
                    (format #t "~a~%" line))
                  (gsettings-runtime-format-status
                   (gsettings-runtime-status gsettings-bin entries)))
        ;; validate：三类声明错误 fail-loud（one-shot 失败由 shepherd
        ;; 记录，绝不 silent ignore）。
        (for-each (lambda (problem)
                    (match problem
                      ((schema key text)
                       (format (current-error-port)
                               "gsettings reconcile: ~a: ~a (~a)~%"
                               text key schema))))
                  (gsettings-runtime-problems gsettings-bin entries))
        (unless (null? (gsettings-runtime-problems gsettings-bin entries))
          (exit 1))
        (let ((status (gsettings-runtime-apply! dconf-bin keyfile)))
          (unless (zero? status)
            (format (current-error-port)
                    "gsettings reconcile: dconf load failed (exit ~a)~%"
                    status)
            (exit 1)))
        (format #t "gsettings reconcile: done~%")))))

;; one-shot Home Shepherd 服务：session D-Bus 就绪后把仓库声明的
;; GSettings 投影进 runtime dconf（desired 声明 build-time 嵌入；
;; Home generation 更新 → Shepherd 重跑本服务 → reconfigure 后立即
;; 生效，无需手工 `blue gsettings apply`）。
(define* (gsettings-reconcile-service desired-settings home-directory)
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
                    (list #$(gsettings-reconcile-wrapper
                             desired-settings home-directory))
                    #:log-file
                    (string-append %user-log-dir
                                   "/gsettings-reconcile.log")))
          (stop #~(make-kill-destructor))))))
