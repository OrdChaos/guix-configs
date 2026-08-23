;;; Machine-owned mutable system state persistence（generic executor）：
;;; /persist/system/state/<backing> → bind → <absolute system consumer>。
;;;
;;; 支持“daemon/GUI 在运行期写标准 /etc、/var/lib 等位置，但
;;; canonical state 留在 /persist/system”的架构位置——例如未来
;;; NetworkManager 的 GUI-created connection profiles：
;;;   /persist/system/state/network-manager/system-connections
;;;     → /etc/NetworkManager/system-connections
;;; （docs/architecture/machine-state.md；本模块不知道具体 daemon）。
;;;
;;; 与 application persistence 的区别（docs/architecture/persistence.md）：
;;;   application-persistence：/persist/data-app → HOME-relative consumer
;;;   machine-state-persistence：/persist/system/state → absolute system
;;;   consumer（root-owned）
;;;
;;; 与 host secret 的区别（docs/architecture/secrets.md）：
;;;   secrets/hosts/<host>：repository 是 authority（declarative
;;;   ciphertext → runtime plaintext）
;;;   /persist/system/state：machine 是 authority（本机产生的 mutable
;;;   state，独立于 repository 持久）
;;;
;;; 不变量（docs/architecture/machine-state.md §13）：
;;;   1. canonical state 只有 /persist/system/state/... 一份；
;;;   2. /etc、/var/lib consumer 只是 projection；
;;;   3. 禁止 boot-copy/shutdown-copy 双副本同步；
;;;   4. 禁止自动迁移已有 consumer 数据；
;;;   5. backing 是 machine-state root 相对路径（无绝对/.. /空/逃逸）；
;;;   6. consumer 必须是 absolute system path，且不得位于
;;;      /gnu/store、/run、/persist、user HOME 或其它 immutable/
;;;      runtime authority root；
;;;   7. exposure 仅 bind-directory；lifecycle 仅 machine-owned；
;;;   8. backing 创建走系统 activation（先于 file-systems 挂载——
;;;      pinned Guix 行为，与 application-persistence 同一审计）；
;;;   9. 不新增 readiness capability（filesystem topology concern）。
;;;
;;; 默认 root ownership：机器状态属 root；不需要 owner/group/mode
;;; 字段时不引入抽象（未来真实 daemon 需要再按最小 contract 扩展）。

(define-module (guixcfg system machine-state-persistence)
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu system file-systems) ; file-system
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure
               #:use-module (guix records)
               #:use-module (guixcfg storage model)   ; persist-mount-point
               #:use-module (guixcfg utils paths)     ; valid-relative-path?（persistence 契约共享）
               #:use-module (srfi srfi-1)             ; every
               #:export (<machine-state-persistence-rule>
                         machine-state-persistence-rule
                         make-machine-state-persistence-rule
                         machine-state-persistence-rule?
                         machine-state-persistence-rule-name
                         machine-state-persistence-rule-backing
                         machine-state-persistence-rule-consumer
                         machine-state-persistence-rule-exposure
                         machine-state-persistence-rule-lifecycle
                         %machine-state-root
                         valid-machine-state-persistence-rule?
                         machine-state-persistence-file-systems
                         machine-state-persistence-activation
                         machine-state-persistence-service))

;; machine-state root = @persist-system 挂载点 + "state"
;; （ownership layering：storage/model.scm 拥有 /persist/system；
;; 本模块拥有其下 /state 子根；未来 daemon 声明拥有
;; /state/<daemon>/...）。
(define %machine-state-root
  (string-append (persist-mount-point "@persist-system") "/state"))

;; consumer 禁止落入的 immutable/runtime authority roots。
(define %forbidden-consumer-roots
  '("/gnu/store" "/run" "/persist" "/home" "/proc" "/sys" "/dev" "/tmp"))

(define %allowed-exposures '(bind-directory))
(define %allowed-lifecycles '(machine-owned))

(define-record-type* <machine-state-persistence-rule>
                     machine-state-persistence-rule make-machine-state-persistence-rule
                     machine-state-persistence-rule?
                     (name machine-state-persistence-rule-name)          ; symbol
                     (backing machine-state-persistence-rule-backing)    ; string：machine-state root 相对
                     (consumer machine-state-persistence-rule-consumer)  ; string：absolute system path
                     (exposure machine-state-persistence-rule-exposure   ; symbol：仅 'bind-directory
                               (default 'bind-directory))
                     (lifecycle machine-state-persistence-rule-lifecycle ; symbol：仅 'machine-owned
                                (default 'machine-owned)))

(define (valid-absolute-consumer? consumer)
  "CONSUMER 是否是合法的 absolute system consumer（非根、不在禁止
roots 下）。"
  (and (string? consumer)
       (string-prefix? "/" consumer)
       (> (string-length consumer) 1)
       (not (string-suffix? "/" consumer))
       (every (lambda (root)
                (not (or (string=? consumer root)
                         (string-prefix? (string-append root "/") consumer))))
              %forbidden-consumer-roots)))

(define (validate-machine-state-persistence-rule rule)
  "RULE 合法性检查；违反抛错（fail closed）。"
  (let ((backing (machine-state-persistence-rule-backing rule))
        (consumer (machine-state-persistence-rule-consumer rule))
        (exposure (machine-state-persistence-rule-exposure rule))
        (lifecycle (machine-state-persistence-rule-lifecycle rule)))
    (unless (valid-relative-path? backing)
      (error "machine-state backing must be a safe relative path"
             (machine-state-persistence-rule-name rule) backing))
    (unless (valid-absolute-consumer? consumer)
      (error "machine-state consumer must be an absolute system path outside immutable/runtime roots"
             (machine-state-persistence-rule-name rule) consumer))
    (unless (memq exposure %allowed-exposures)
      (error "unsupported machine-state exposure"
             (machine-state-persistence-rule-name rule) exposure))
    (unless (memq lifecycle %allowed-lifecycles)
      (error "unsupported machine-state lifecycle"
             (machine-state-persistence-rule-name rule) lifecycle))
    #t))

(define (valid-machine-state-persistence-rule? rule)
  "RULE 是否合法（不抛错版本，供测试/筛选）。"
  (catch #t
    (lambda () (validate-machine-state-persistence-rule rule) #t)
    (lambda (k . a) #f)))

(define (machine-state-persistence-file-systems rules)
  "RULES 的 bind mount 声明（/persist/system/state/<backing> →
<consumer>）。挂载点由 file-systems 阶段创建（create-mount-point?
#t）；backing 与 consumer parent 由 activation 准备。"
  (map (lambda (rule)
         (validate-machine-state-persistence-rule rule)
         (file-system
          (device (string-append %machine-state-root "/"
                                 (machine-state-persistence-rule-backing rule)))
          (mount-point (machine-state-persistence-rule-consumer rule))
          (type "none")
          (flags '(bind-mount))
          (create-mount-point? #t)
          (check? #f)))
       rules))

(define (machine-state-persistence-activation rules)
  "activation gexp：创建 backing 目录（root-owned）与 consumer parent
目录。只补缺失目录、不重建已有数据（不自动迁移/覆盖 consumer data）。
与 application-persistence 同一 ordering 审计：activation 先于
shepherd file-systems 服务挂载（boot/init/reconfigure 三路径安全）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (for-each
                             (lambda (spec)
                               (let* ((backing (car spec))
                                      (consumer (cadr spec)))
                                 (mkdir-p (string-append
                                           #$%machine-state-root "/" backing))
                                 (mkdir-p (dirname consumer))))
                             (quote
                               (#$@(map (lambda (rule)
                                          (list (machine-state-persistence-rule-backing
                                                 rule)
                                                (machine-state-persistence-rule-consumer
                                                 rule)))
                                        rules)))))))

(define (machine-state-persistence-service rules)
  "把 RULES 的 backing/parent 创建挂到系统 activation。RULES 为空时
返回 #f（不产生无意义服务）。"
  (if (null? rules)
    #f
    (simple-service 'machine-state-persistence activation-service-type
                    (machine-state-persistence-activation rules))))
