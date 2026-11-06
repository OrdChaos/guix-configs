;;; Application persistence generic executor（System owns）：
;;; /persist/data-app/<backing> → bind → /home/<user>/<consumer>。
;;;
;;; 本模块是 generic mechanism，不知道 Firefox/Flatpak 等具体应用
;;; 名称——rule 由 application definition 提供（<application> 的
;;; persistence 字段），host 经 registry 聚合。exposure 支持两种
;;; bind 形态（docs/architecture/persistence.md）：
;;;   bind-directory  backing/consumer 都是 directory；
;;;   bind-file       backing/consumer 都是 regular file（file→file
;;;                   bind；适用于直接写同一路径、不做 temp-file+
;;;                   rename 原子替换的应用单文件状态）。
;;; 明确不实现 symlink/boot-copy/backup/migration。
;;;
;;; seed-once（seeds 字段）：rule 可声明一次性初始状态（如
;;; settings.toml 的基础配置）。首次 activation 时目标不存在才写入
;;; （原子落盘 + marker 记录），此后 repository 永久放弃该文件
;;; ownership——绝不覆盖/同步/修正（含 seed 源更新）。机制在
;;; (guixcfg utils seed-once)，本模块只做声明、校验与激活接线
;;; （docs/architecture/persistence.md（seed-once））。
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
;;;   6. bind-file 的 backing/consumer 都必须是 regular file（首次
;;;      deployment 由 activation 建空文件；类型错误 fail closed，
;;;      绝不静默重建/替换已有 state）；
;;;   7. 挂载属 file-systems topology——不新增 readiness capability。
;;;
;;; 三路径安全性（pinned Guix 行为审计）：backing 目录/文件创建走
;;; 系统 activation（boot：activation 先于 shepherd file-systems 服务
;;; 挂载；system init / reconfigure：都会运行 activation），因此 bind
;;; mount（file-systems 阶段）的 source 在挂载前已存在。

(define-module (guixcfg system application-persistence)
  #:use-module (gnu services) ;simple-service
  #:use-module (gnu system file-systems) ;file-system
  #:use-module (guixcfg storage model) ;persist-mount-point（/persist 语义路径 authority）
  #:use-module (guixcfg utils paths) ;valid-relative-path?（persistence 契约共享）
  #:use-module (guixcfg utils home-path) ;ensure-home-parent-directories!
  #:use-module (guixcfg utils seed-once) ;seed-once-file!、%seed-marker-suffix
  #:use-module (guixcfg system mount-metadata) ;%persistent-home-mount-options
  #:use-module (guixcfg system persistence)
  #:use-module (guixcfg utils module-closure) ;guixcfg-module-select?
  #:use-module (guix gexp)
  #:use-module (guix modules) ;source-module-closure
  #:use-module (guix records)
  #:use-module (srfi srfi-1) ;append-map、filter
  #:export (<application-persistence-rule> application-persistence-rule
            make-application-persistence-rule
            application-persistence-rule?
            application-persistence-rule-name
            application-persistence-rule-backing
            application-persistence-rule-consumer
            application-persistence-rule-exposure
            application-persistence-rule-lifecycle
            application-persistence-rule-seeds
            application-persistence-rule-seed-variants
            application-persistence-rule-for-variant
            %application-persistence-root
            valid-application-persistence-rule?
            application-persistence-projections
            application-persistence-file-systems
            application-persistence-activation
            application-persistence-service))

;; /persist/data-app（@persist-data-app 子卷；storage/model.scm）。
(define %application-persistence-root
  (persist-mount-point "@persist-data-app"))

;; 禁止作为整体 consumer 的全局目录（精确或前缀都拒绝）。
(define %forbidden-consumers
  '(".config" ".local" ".local/share" ".cache"))

;; exposure / lifecycle 当前合法值（契约显式；扩展必须改这里
;; 和 docs）。
(define %allowed-exposures
  '(bind-directory bind-file))
(define %allowed-lifecycles
  '(application-owned))

(define-record-type* <application-persistence-rule>
                     application-persistence-rule
                     make-application-persistence-rule
  application-persistence-rule?
  (name application-persistence-rule-name) ;symbol
  (backing application-persistence-rule-backing) ;string：/persist/data-app 下相对路径
  (consumer application-persistence-rule-consumer) ;string：HOME 相对路径
  (exposure application-persistence-rule-exposure ;symbol：'bind-directory | 'bind-file
            (default 'bind-directory))
  (lifecycle application-persistence-rule-lifecycle ;symbol：仅 'application-owned
             (default 'application-owned))
  (seeds application-persistence-rule-seeds ;list of (target source)
         (default '()))
  (seed-variants application-persistence-rule-seed-variants ;alist variant -> seeds
                 (default '())))

(define (validate-seed-spec spec)
  "SEED-SPEC 是 (target source) 两元素列表（与 configuration
variants 的 (target source) 约定一致）：target 是 backing 内相对
路径，source 必须是 file-like（store 化，repository 只是 deployment
input——AGENT.md §12）。非法抛错（fail closed）。"
  (unless (and (list? spec)
               (= 2
                  (length spec))
               (string? (car spec)))
    (error "application persistence seed must be a (target source) pair" spec))
  (let ((target (car spec)))
    (unless (valid-relative-path? target)
      (error
       "application persistence seed target must be a safe relative path"
       target))
    (when (string-suffix? %seed-marker-suffix target)
      (error
       "application persistence seed target must not end with the marker suffix"
       target)))
  (unless (file-like? (cadr spec))
    (error "application persistence seed source must be a file-like"
           (cadr spec))))

(define (validate-seed-variants variants)
  "SEED-VARIANTS 是 (variant . seeds) 的 alist：variant 是逻辑变体名
（如 'laptop），seeds 是该变体的**完整** (target source) 列表——
替换 base seeds，不做增量 merge（seed-once 只写一次，部分覆盖会留下
混合状态）。host 只做 variant selection，不接触文件或路径
（docs/architecture/applications.md（Host-agnostic boundary））。"
  (unless (list? variants)
    (error "application persistence seed-variants must be an alist"
           variants))
  (let loop ((rest variants) (seen '()))
    (unless (null? rest)
      (let ((entry (car rest)))
        (unless (and (pair? entry)
                     (symbol? (car entry)))
          (error "application persistence seed-variant key must be a symbol"
                 entry))
        (when (memq (car entry) seen)
          (error "duplicate application persistence seed-variant"
                 (car entry)))
        (unless (list? (cdr entry))
          (error "application persistence seed-variant seeds must be a list"
                 entry))
        (for-each validate-seed-spec (cdr entry))
        (loop (cdr rest) (cons (car entry) seen))))))

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
      (error
       "application persistence consumer must be a HOME-relative safe path"
       (application-persistence-rule-name rule) consumer))
    (when (forbidden-consumer? consumer)
      (error
       "application persistence consumer must not cover whole ~/.config|.local|.local/share|.cache"
       (application-persistence-rule-name rule) consumer))
    (unless (memq exposure %allowed-exposures)
      (error "unsupported application persistence exposure"
             (application-persistence-rule-name rule) exposure))
    (unless (memq lifecycle %allowed-lifecycles)
      (error "unsupported application persistence lifecycle"
             (application-persistence-rule-name rule) lifecycle))
    ;; seeds 语义是"backing 目录内相对 target 的首次初始化"——只对
    ;; bind-directory 成立（bind-file 的 backing 本身就是单文件，
    ;; seed target 无从相对）。fail closed 拒绝该组合；带变体的 seed
    ;; 同样是 backing-relative，一并拒绝。
    (when (and (eq? exposure
                    'bind-file)
               (or (pair? (application-persistence-rule-seeds rule))
                   (pair? (application-persistence-rule-seed-variants
                           rule))))
      (error
       "application persistence bind-file rule must not declare seeds or seed-variants"
       (application-persistence-rule-name rule)))
    (for-each validate-seed-spec
              (application-persistence-rule-seeds rule))
    (validate-seed-variants
     (application-persistence-rule-seed-variants rule))
    #t))

(define (valid-application-persistence-rule? rule)
  "RULE 是否合法（不抛错版本，供测试/筛选）。"
  (catch #t
         (lambda ()
           (validate-application-persistence-rule rule) #t)
         (lambda (k . a)
           #f)))

(define (application-persistence-rule-for-variant rule variant)
  "按逻辑 VARIANT 选择 seed 变体：rule 的 seed-variants 声明了该变体
时，用其完整 seeds 列表替换 base seeds；VARIANT 为 #f 或未声明该
变体时原样返回 rule（base seed 继续作为可移植缺省）。其余字段
（name/backing/consumer/exposure/lifecycle）一律不变。"
  (let ((chosen (and variant
                     (assq-ref (application-persistence-rule-seed-variants
                                rule)
                               variant))))
    (if chosen
        (application-persistence-rule (inherit rule) (seeds chosen))
        rule)))

(define (application-persistence-projections rules user)
  "Convert application rules to generic persistence projections.  The
consumer is resolved against USER's home; ownership is the user; seeds and
bind-file exposure are preserved."
  (let ((home (string-append "/home/" user)))
    (map (lambda (rule)
           (validate-application-persistence-rule rule)
           (persistence-projection
             (name (application-persistence-rule-name rule))
             (root %application-persistence-root)
             (backing (application-persistence-rule-backing rule))
             (consumer (string-append home "/"
                                      (application-persistence-rule-consumer
                                       rule)))
             (exposure (application-persistence-rule-exposure rule))
             (owner 'user)
             (owner-user user)
             (mode #f)
             (options %persistent-home-mount-options)
             (home home)
             (seeds (application-persistence-rule-seeds rule))))
         rules)))

(define (application-persistence-file-systems rules user)
  "RULES 的 bind mount 声明（/persist/data-app/<backing> →
/home/<USER>/<consumer>），由通用 persistence executor 派生。"
  (persistence-set-file-systems
    (persistence-set (projections
                       (application-persistence-projections rules user)))))

(define (application-persistence-activation rules user)
  "activation gexp：由通用 persistence executor 创建 backing、consumer
挂载点、ownership、seed-once；bind-file 语义与规则校验保持一致。"
  (persistence-set-activation
    (persistence-set (projections
                       (application-persistence-projections rules user)))))

(define (application-persistence-service rules user)
  "把 RULES 的 activation 挂到系统 activation。RULES 为空时返回 #f。"
  (persistence-set-service
    (persistence-set (projections
                       (application-persistence-projections rules user)))))
