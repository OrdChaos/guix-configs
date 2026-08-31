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
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu system file-systems) ; file-system
               #:use-module (guixcfg storage model)   ; persist-mount-point（/persist 语义路径 authority）
               #:use-module (guixcfg utils paths)     ; valid-relative-path?（persistence 契约共享）
               #:use-module (guixcfg utils home-path) ; ensure-home-parent-directories!
               #:use-module (guixcfg utils seed-once) ; seed-once-file!、%seed-marker-suffix
               #:use-module (guixcfg system mount-metadata) ; %persistent-home-mount-options
               #:use-module (guixcfg utils module-closure) ; guixcfg-module-select?
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
                         application-persistence-rule-seeds
                         %application-persistence-root
                         valid-application-persistence-rule?
                         application-persistence-file-systems
                         application-persistence-activation
                         application-persistence-service))

;; /persist/data-app（@persist-data-app 子卷；storage/model.scm）。
(define %application-persistence-root (persist-mount-point "@persist-data-app"))

;; 禁止作为整体 consumer 的全局目录（精确或前缀都拒绝）。
(define %forbidden-consumers
  '(".config" ".local" ".local/share" ".cache"))

;; exposure / lifecycle 当前合法值（契约显式；扩展必须改这里
;; 和 docs）。
(define %allowed-exposures '(bind-directory bind-file))
(define %allowed-lifecycles '(application-owned))

(define-record-type* <application-persistence-rule>
                     application-persistence-rule make-application-persistence-rule
                     application-persistence-rule?
                     (name application-persistence-rule-name)            ; symbol
                     (backing application-persistence-rule-backing)      ; string：/persist/data-app 下相对路径
                     (consumer application-persistence-rule-consumer)    ; string：HOME 相对路径
                     (exposure application-persistence-rule-exposure     ; symbol：'bind-directory | 'bind-file
                               (default 'bind-directory))
                     (lifecycle application-persistence-rule-lifecycle   ; symbol：仅 'application-owned
                                (default 'application-owned))
                     (seeds application-persistence-rule-seeds           ; list of (target source)
                            (default '())))

(define (validate-seed-spec spec)
  "SEED-SPEC 是 (target source) 两元素列表（与 configuration
variants 的 (target source) 约定一致）：target 是 backing 内相对
路径，source 必须是 file-like（store 化，repository 只是 deployment
input——AGENT.md §12）。非法抛错（fail closed）。"
  (unless (and (list? spec) (= 2 (length spec)) (string? (car spec)))
    (error "application persistence seed must be a (target source) pair"
           spec))
  (let ((target (car spec)))
    (unless (valid-relative-path? target)
      (error "application persistence seed target must be a safe relative path"
             target))
    (when (string-suffix? %seed-marker-suffix target)
      (error "application persistence seed target must not end with the marker suffix"
             target)))
  (unless (file-like? (cadr spec))
    (error "application persistence seed source must be a file-like"
           (cadr spec))))

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
    ;; seeds 语义是"backing 目录内相对 target 的首次初始化"——只对
    ;; bind-directory 成立（bind-file 的 backing 本身就是单文件，
    ;; seed target 无从相对）。fail closed 拒绝该组合。
    (when (and (eq? exposure 'bind-file)
               (pair? (application-persistence-rule-seeds rule)))
      (error "application persistence bind-file rule must not declare seeds"
             (application-persistence-rule-name rule)))
    (for-each validate-seed-spec (application-persistence-rule-seeds rule))
    #t))

(define (valid-application-persistence-rule? rule)
  "RULE 是否合法（不抛错版本，供测试/筛选）。"
  (catch #t
    (lambda () (validate-application-persistence-rule rule) #t)
    (lambda (k . a) #f)))

(define (application-persistence-file-systems rules user)
  "RULES 的 bind mount 声明（/persist/data-app/<backing> →
/home/<USER>/<consumer>）。挂载点由 file-systems 阶段创建
（bind-directory：create-mount-point? #t）；intermediate parent
ownership 由 activation 恢复。options 带桌面集成 metadata
（x-gvfs-hide, x-gvfs-trash——共享常量 (guixcfg system mount-metadata)，
与 user-persistence 同一语义：GVfs 隐藏实现性挂载 + 允许 mount-local
trash）。

bind-file 必须 create-mount-point? #f：shepherd 对
create-mount-point? 的实现是预 mkdir-p（pinned Guix
gnu/services/base.scm file-system-shepherd-service）——会建出
directory，而 file→file bind 要求 regular-file 挂载点。regular-file
挂载点由 activation 预建（三路径安全）；pinned Guix 的
mount-file-system 对 bind mount + non-directory source 也原生自动
创建 regular-file target（gnu/build/file-systems.scm——防御第二层）。"
  (map (lambda (rule)
         (validate-application-persistence-rule rule)
         (file-system
          (device (string-append %application-persistence-root "/"
                                 (application-persistence-rule-backing rule)))
          (mount-point (string-append "/home/" user "/"
                                      (application-persistence-rule-consumer rule)))
          (type "none")
          (flags '(bind-mount))
          (options %persistent-home-mount-options)
          (create-mount-point? (eq? 'bind-directory
                                    (application-persistence-rule-exposure
                                     rule)))
          (check? #f)))
       rules))

(define (application-persistence-activation rules user)
  "activation gexp：准备 backing 与 consumer 挂载点（bind-directory：
backing 目录 + consumer parent 层级 ownership；bind-file：backing
parent 目录 + backing regular file + consumer parent 层级 + consumer
regular-file 挂载点——类型错误 fail closed，绝不静默重建/替换已有
state），并对 rule 声明的 seeds 执行 seed-once（目标从未存在时原子
写入初始状态；此后 repository 永久放弃 ownership——机制见
(guixcfg utils seed-once)）。
create-mount-point? 以 root 建挂载点，本 activation 的 mkdir-p 也以
root 建出整条 parent 路径，必须把【所有中间层】都归还 USER。只
chown 直接 parent 会留下 root-owned 的 ~/.local：后续以 USER 身份
运行的 Guix Home activation（guix-home-user → he/activate → mkdir-p
$XDG_DATA_HOME）会在 root-owned 目录下 mkdir 时 EACCES，整个 Home
activation 失败（boot 实测 2026-08-19；回归测试
test-runtime-exec.scm AP1）。只补缺失目录/文件、不重建已有数据
（persistence 不自动迁移/覆盖/删除 consumer data）。seed 检查发生
在 canonical backing 侧（/persist/data-app/<backing>，needed-for-boot
子卷挂载先于 activation，绑定投影在 file-systems 阶段之后）——
持久化状态与 seed 判断天然同一位置：已有持久化 state 时 seed-once
直接看到目标已存在，不做任何事（生命周期顺序正确，无 restore/seed
竞态）。没有任何 rule 声明 seeds 时生成与旧版完全相同的 activation
（seed 代码按构造期条件拼接，不给无 seed 的 rule 增加运行时依赖）。"
  (define has-seeds?
    (any (lambda (rule)
           (pair? (application-persistence-rule-seeds rule)))
         rules))
  (define seed-closure-modules
    (if has-seeds? '((guixcfg utils seed-once)) '()))
  (define seed-loop
    (if has-seeds?
      #~(for-each
         (lambda (entry)
           (let ((dest (string-append src "/" (car entry)))
                 (marker (string-append src "/" (car entry)
                                        #$%seed-marker-suffix)))
             (case (seed-once-file! dest (cadr entry) marker)
               ((seeded)
                (chown dest uid gid)
                (chown marker uid gid))
               ((preserved)
                (chown marker uid gid)))))
         seeds)
      ;; 空语句：#~#t（不能用 #~(begin)——空 begin 是语法错误，
      ;; AP1 runtime-exec 实测捕获）。
      #~#t))
  (with-imported-modules
   (source-module-closure `((guix build utils)
                            (guixcfg utils home-path)
                            ,@seed-closure-modules)
                          #:select? guixcfg-module-select?)
   #~(begin
      (use-modules (guix build utils)
                   (guixcfg utils home-path)
                   #$@seed-closure-modules)
      (let* ((uid (passwd:uid (getpw #$user)))
             (gid (passwd:gid (getpw #$user)))
             (home (string-append "/home/" #$user)))
        (for-each
         (lambda (spec)
           (let* ((backing (car spec))
                  (consumer (cadr spec))
                  (exposure (caddr spec))
                  (seeds (cadddr spec))
                  (src (string-append
                        #$%application-persistence-root
                        "/" backing))
                  (dst (string-append home "/" consumer)))
             ;; consumer parent 全层级归还 USER（共享原语：
             ;; (guixcfg utils home-path)；/home/USER 本身由
             ;; user-persistence activation 负责）。
             (ensure-home-parent-directories! home consumer uid gid)
             (case exposure
               ((bind-directory)
                (mkdir-p src)
                (chown src uid gid)
                ;; seed-once：目标从未存在才写入；seed 后 repo 永久
                ;; 放弃 ownership（marker 记录；写出的文件归还 USER）。
                #$seed-loop)
               ((bind-file)
                ;; backing parent（/persist/data-app/<app> 层级）先建
                ;; ——call-with-output-file 不会建父目录。backing：
                ;; canonical mutable state 唯一权威——不存在时建空
                ;; regular file；存在但非 regular file → fail closed
                ;; （绝不静默重建/替换已有 state）。
                (mkdir-p (dirname src))
                (if (file-exists? src)
                    (unless (eq? 'regular (stat:type (stat src)))
                      (error "application persistence bind-file backing \
exists but is not a regular file"
                             src))
                    (begin
                      (call-with-output-file src (lambda (p) #t))
                      (chown src uid gid)))
                ;; consumer mount point：regular file，不是 directory
                ;; （file→file bind 要求；bind-directory 的 shepherd
                ;; mkdir-p 语义在此不适用）。挂载已激活时该文件存在
                ;; ——幂等 no-op；存在但非 regular → fail closed。
                (if (file-exists? dst)
                    (unless (eq? 'regular (stat:type (stat dst)))
                      (error "application persistence bind-file consumer \
mount point exists but is not a regular file"
                             dst))
                    (begin
                      (call-with-output-file dst (lambda (p) #t))
                      (chown dst uid gid)))))))
         (quote
           (#$@(map (lambda (rule)
                      (list (application-persistence-rule-backing
                             rule)
                            (application-persistence-rule-consumer
                             rule)
                            (application-persistence-rule-exposure
                             rule)
                            (map (lambda (s)
                                   (list (car s) (cadr s)))
                                 (application-persistence-rule-seeds
                                  rule))))
                    rules))))))))

(define (application-persistence-service rules user)
  "把 RULES 的 backing/parent 创建挂到系统 activation（bind mounts
本身经 application-persistence-file-systems 声明）。RULES 为空时
返回 #f（不产生无意义服务）。"
  (if (null? rules)
    #f
    (simple-service 'application-persistence activation-service-type
                    (application-persistence-activation rules user))))
