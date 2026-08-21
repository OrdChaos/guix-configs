;;; Application persistence generic executor（System owns）：
;;; /persist/data-app/<backing> → bind → /home/<user>/<consumer>。
;;;
;;; 本模块是 generic mechanism，不知道 Firefox/Flatpak 等具体应用
;;; 名称——rule 由 application definition 提供（<application> 的
;;; persistence 字段），host 经 registry 聚合。第一版只实现
;;; directory bind；明确不实现 symlink/single-file/boot-copy/
;;; seed-once/backup/migration（docs/architecture/persistence.md）。
;;;
;;; 不变量（docs/architecture/persistence.md §Application
;;; persistence）：
;;;   1. /persist/data-app/<backing> 是 mutable app state 的唯一
;;;      canonical backing；consumer 路径只是 bind projection；
;;;   2. 禁止持久化整个 ~/.config / ~/.local / ~/.local/share /
;;;      ~/.cache（rule consumer 必须精确到单个应用状态）；
;;;   3. backing/consumer 严格 validation（无 ..、无绝对路径、
;;;      非空、consumer 非全局目录整体）；
;;;   4. 不产生 /persist/data-nobackup mapping（backing 永远相对
;;;      /persist/data-app）；
;;;   5. intermediate consumer parent ownership 由 activation 恢复
;;;      （create-mount-point? 与 activation 的 mkdir-p 都以 root 建
;;;      HOME 层级——【每一层】都必须归还 USER；只 chown 直接 parent
;;;      会留下 root-owned 的 ~/.local，USER 后续 mkdir ~/.local/share
;;;      等 EACCES，Home activation 整体失败）；
;;;   6. 挂载属 file-systems topology——不新增 readiness capability。
;;;
;;; 三路径安全性（pinned Guix 行为审计）：backing 目录创建走系统
;;; activation（boot：activation 先于 shepherd file-systems 服务挂载；
;;; system init / reconfigure：都会运行 activation），因此 bind
;;; mount（file-systems 阶段）的 source 在挂载前已存在。

(define-module (guixcfg system application-persistence)
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu system file-systems) ; file-system
               #:use-module (guixcfg storage model)   ; persist-mount-point（/persist 语义路径 authority）
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure
               #:use-module (guix records)
               #:use-module (srfi srfi-1)             ; append-map、filter
               #:export (<application-persistence-rule>
                         application-persistence-rule
                         make-application-persistence-rule
                         application-persistence-rule?
                         application-persistence-rule-name
                         application-persistence-rule-backing
                         application-persistence-rule-consumer
                         application-persistence-rule-exposure
                         application-persistence-rule-lifecycle
                         %application-persistence-root
                         valid-application-persistence-rule?
                         validate-application-persistence-rule
                         application-persistence-file-systems
                         application-persistence-activation
                         application-persistence-service))

;; /persist/data-app（@persist-data-app 子卷；storage/model.scm）。
(define %application-persistence-root (persist-mount-point "@persist-data-app"))

;; 禁止作为整体 consumer 的全局目录（精确或前缀都拒绝）。
(define %forbidden-consumers
  '(".config" ".local" ".local/share" ".cache"))

;; exposure / lifecycle 当前唯一合法值（契约显式；扩展必须改这里
;; 和 docs）。
(define %allowed-exposures '(bind-directory))
(define %allowed-lifecycles '(application-owned))

(define-record-type* <application-persistence-rule>
                     application-persistence-rule make-application-persistence-rule
                     application-persistence-rule?
                     (name application-persistence-rule-name)            ; symbol
                     (backing application-persistence-rule-backing)      ; string：/persist/data-app 下相对路径
                     (consumer application-persistence-rule-consumer)    ; string：HOME 相对路径
                     (exposure application-persistence-rule-exposure     ; symbol：仅 'bind-directory
                               (default 'bind-directory))
                     (lifecycle application-persistence-rule-lifecycle   ; symbol：仅 'application-owned
                                (default 'application-owned)))

(define (valid-relative-path? p)
  "P 是否是合法的相对路径（非空、非绝对、无 .. 逃逸）。"
  (and (string? p)
       (> (string-length p) 0)
       (not (string-prefix? "/" p))
       (not (string=? p ".."))
       (not (string-prefix? "../" p))
       (not (string-contains p "/../"))
       (not (string-suffix? "/.." p))))

(define (forbidden-consumer? consumer)
  "CONSUMER 是否是禁止整体持久化的全局目录（精确匹配——任务契约
§7.6：不允许这些目录“作为整体 consumer”；其下的应用子目录
（如 .config/foo、.local/share/foo）是合法精确 consumer，见
docs/architecture/persistence.md 与 secrets.md 的 flatpak 例子）。"
  (member consumer %forbidden-consumers))

(define (validate-application-persistence-rule rule)
  "RULE 合法性检查；违反抛错（fail closed）。"
  (let ((backing (application-persistence-rule-backing rule))
        (consumer (application-persistence-rule-consumer rule))
        (exposure (application-persistence-rule-exposure rule))
        (lifecycle (application-persistence-rule-lifecycle rule)))
    (unless (valid-relative-path? backing)
      (error "application persistence backing must be a safe relative path"
             (application-persistence-rule-name rule) backing))
    (unless (valid-relative-path? consumer)
      (error "application persistence consumer must be a HOME-relative safe path"
             (application-persistence-rule-name rule) consumer))
    (when (forbidden-consumer? consumer)
      (error "application persistence consumer must not cover whole ~/.config|.local|.local/share|.cache"
             (application-persistence-rule-name rule) consumer))
    (unless (memq exposure %allowed-exposures)
      (error "unsupported application persistence exposure"
             (application-persistence-rule-name rule) exposure))
    (unless (memq lifecycle %allowed-lifecycles)
      (error "unsupported application persistence lifecycle"
             (application-persistence-rule-name rule) lifecycle))
    #t))

(define (valid-application-persistence-rule? rule)
  "RULE 是否合法（不抛错版本，供测试/筛选）。"
  (catch #t
    (lambda () (validate-application-persistence-rule rule) #t)
    (lambda (k . a) #f)))

(define (application-persistence-file-systems rules user)
  "RULES 的 bind mount 声明（/persist/data-app/<backing> →
/home/<USER>/<consumer>）。挂载点由 file-systems 阶段创建
（create-mount-point? #t）；intermediate parent ownership 由
activation 恢复。"
  (map (lambda (rule)
         (validate-application-persistence-rule rule)
         (file-system
          (device (string-append %application-persistence-root "/"
                                 (application-persistence-rule-backing rule)))
          (mount-point (string-append "/home/" user "/"
                                      (application-persistence-rule-consumer rule)))
          (type "none")
          (flags '(bind-mount))
          (create-mount-point? #t)
          (check? #f)))
       rules))

(define (application-persistence-activation rules user)
  "activation gexp：创建 backing 目录（owner=USER）并恢复 consumer
parent 层级 ownership——create-mount-point? 以 root 建挂载点，本
activation 的 mkdir-p 也以 root 建出整条 parent 路径，必须把【所有
中间层】都归还 USER。只 chown 直接 parent 会留下 root-owned 的
~/.local：后续以 USER 身份运行的 Guix Home activation
（guix-home-user → he/activate → mkdir-p $XDG_DATA_HOME）会在
root-owned 目录下 mkdir 时 EACCES，整个 Home activation 失败
（boot 实测 2026-08-19；回归测试 test-runtime-exec.scm AP1）。
只补缺失目录、不重建已有数据（persistence 不自动迁移/覆盖/删除
consumer data）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (let* ((uid (passwd:uid (getpw #$user)))
                                   (gid (passwd:gid (getpw #$user)))
                                   (home (string-append "/home/" #$user)))
                              (for-each
                               (lambda (spec)
                                 (let* ((backing (car spec))
                                        (consumer (cadr spec))
                                        (src (string-append
                                              #$%application-persistence-root
                                              "/" backing)))
                                   (mkdir-p src)
                                   (chown src uid gid)
                                   ;; consumer parent 全层级归还 USER：
                                   ;; 从最深 parent 逐级向上直到 home
                                   ;; （/home/USER 本身由 user-persistence
                                   ;; activation 负责）。
                                   (let loop ((dir (dirname
                                                    (string-append home "/"
                                                                   consumer))))
                                     (unless (string=? dir home)
                                       (mkdir-p dir)
                                       (chown dir uid gid)
                                       (loop (dirname dir))))))
                               (quote
                                 (#$@(map (lambda (rule)
                                            (list (application-persistence-rule-backing
                                                   rule)
                                                  (application-persistence-rule-consumer
                                                   rule)))
                                          rules))))))))

(define (application-persistence-service rules user)
  "把 RULES 的 backing/parent 创建挂到系统 activation（bind mounts
本身经 application-persistence-file-systems 声明）。RULES 为空时
返回 #f（不产生无意义服务）。"
  (if (null? rules)
    #f
    (simple-service 'application-persistence activation-service-type
                    (application-persistence-activation rules user))))
