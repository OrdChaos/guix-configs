;;; Root generation 生命周期模型：状态文件、启动模式、启动决策与清理规则。
;;; 本模块是纯模型——只描述“状态应该是什么样、这次启动该做什么”，
;;; 不做任何 Btrfs / 挂载操作（initrd 和用户态服务分别消费这些决策）。
;;; 对应 docs/storage.md 第 17 章（root generation）与第 19 章（机器事实）。

(define-module (guixcfg storage root-generation)
               #:use-module (guix records)  ; define-record-type*
               #:use-module (guixcfg storage model)  ; root-generation-name 等命名
               #:use-module (srfi srfi-1)   ; fold、delete、take 等列表工具
               #:use-module (srfi srfi-13)  ; 字符串工具
               #:export (;; 状态文件位置
                         %root-generations-dir-name
                         %state-file-name
                         state-file-path
                         ;; 状态记录
                         <root-state>
                         root-state make-root-state root-state?
                         root-state-next-generation
                         root-state-current-generation
                         root-state-last-good-generation
                         root-state-created-at
                         root-state-boot-status
                         root-state-source-template
                         root-state-system-revision
                         ;; 状态 <-> alist 序列化
                         initial-state
                         state->alist
                         alist->state
                         ;; 启动模式
                         <boot-mode>
                         boot-mode make-boot-mode boot-mode?
                         boot-mode-kind boot-mode-generation
                         parse-boot-mode
                         %default-boot-mode
                         ;; 启动决策
                         <boot-plan>
                         boot-plan make-boot-plan boot-plan?
                         boot-plan-target-subvolume
                         boot-plan-create-from-template?
                         boot-plan-state-after
                         plan-boot
                         ;; 状态文件 IO（原子写、.prev 回退）
                         read-state
                         write-state!
                         ;; 用户态确认与清理
                         confirm-boot
                         prune-created-at
                         generations-to-delete))

;;; ────────────────────────────────────────────────────────────
;;; 状态文件位置（docs/storage.md 第 17.7 节）。
;;;
;;; 状态放在 @persist-system 子卷里。同一份状态有两个视角：
;;;   启动后的系统：  /persist/system/root-generations/state.scm
;;;                   （@persist-system 挂载在 /persist/system）
;;;   initrd：        <顶层挂载点>/@persist-system/root-generations/state.scm
;;; 因此这里只定义子卷内的相对路径，由调用方拼接 @persist-system 的挂载点。

(define %root-generations-dir-name "root-generations")
(define %state-file-name "state.scm")

(define (state-file-path persist-system-mount)
  "@persist-system 子卷挂载在 PERSIST-SYSTEM-MOUNT 时，状态文件的完整路径。"
  (string-append persist-system-mount "/"
                 %root-generations-dir-name "/" %state-file-name))

;;; ────────────────────────────────────────────────────────────
;;; 状态记录（docs/storage.md 第 17.7 节要求的字段）。

(define-record-type* <root-state>
                     root-state make-root-state
                     root-state?
                     ;; 下一个待分配的 generation 编号（整数）
                     (next-generation       root-state-next-generation)
                     ;; 本次启动使用的 generation；安装后尚未首次启动时为 #f
                     (current-generation    root-state-current-generation)
                     ;; 最近一次被用户态确认“启动成功”的 generation；未确认为 #f
                     (last-good-generation  root-state-last-good-generation)
                     ;; generation → Unix 时间的 alist，仅作 metadata（第 17.1 节）
                     (created-at            root-state-created-at
                                            (default '()))
                     ;; 符号：first-boot（装完未启动）/ trying（已启动未确认）/ ok（已确认）
                     (boot-status           root-state-boot-status)
                     ;; 当前 generation 快照自哪个模板（子卷名字符串）
                     (source-template       root-state-source-template
                                            (default "@root-template"))
                     ;; 构建系统的 guix-configs Git 修订（字符串或 #f，构建期填入）
                     (system-revision       root-state-system-revision
                                            (default #f)))

(define (initial-state now)
  "安装期提交完成时的初始状态：@root-0 已就绪但从未启动（第 17.3、17.4 节）。
NOW 是 Unix 时间（整数），作为 @root-0 的创建时间 metadata。"
  (root-state (next-generation 1)
              (current-generation 0)
              (last-good-generation #f)
              (created-at `((0 . ,now)))
              (boot-status 'first-boot)
              (source-template "@root-template")))

;;; ────────────────────────────────────────────────────────────
;;; 状态文件 IO。
;;;
;;; 写入必须是事务式的：call-with-output-file 会先 truncate 原文件，
;;; 断电会得到空文件/半截 Scheme，下次启动直接死在 initrd。
;;; 因此：写 .new → fsync → rename（原子替换），并保留上一份 .prev
;;; 作为损坏时的回退。initrd、用户态服务、安装期提交三处都必须走这里，
;;; 不允许直接 call-with-output-file 写状态文件。

(define (state-prev-path path)
  (string-append path ".prev"))

(define (write-state! path state)
  "把 STATE 原子地写入 PATH：state.scm.new → fsync → rename，
并在覆盖前把现有文件复制为 .prev 备份。"
  (let ((new  (string-append path ".new"))
        (prev (state-prev-path path)))
    (when (file-exists? path)
      (copy-file path prev))
    (call-with-output-file new
                           (lambda (port)
                             (write (state->alist state) port)
                             (newline port)
                             ;; 落盘后再 rename，保证 rename 指向的内容完整
                             (fsync port)))
    (rename-file new path)))

(define (read-state path)
  "读取 PATH 的状态；主文件损坏时回退到 .prev。都不存在/都损坏则报错。"
  (define (try p)
    (alist->state (call-with-input-file p read)))
  (if (file-exists? path)
    (catch #t
      (lambda () (try path))
      (lambda (key . args)
        (let ((prev (state-prev-path path)))
          (if (file-exists? prev)
            (try prev)
            (apply throw key args)))))
    (let ((prev (state-prev-path path)))
      (if (file-exists? prev)
        (try prev)
        (error "root generation 状态文件不存在" path)))))

;;; ────────────────────────────────────────────────────────────
;;; 序列化：与 facts 文件相同的 alist 形式（write/read 往返）。

(define (state->alist state)
  "把 <root-state> 转成可 write 到状态文件的 alist。"
  `((next-generation      . ,(root-state-next-generation state))
    (current-generation   . ,(root-state-current-generation state))
    (last-good-generation . ,(root-state-last-good-generation state))
    (created-at           . ,(root-state-created-at state))
    (boot-status          . ,(root-state-boot-status state))
    (source-template      . ,(root-state-source-template state))
    (system-revision      . ,(root-state-system-revision state))))

(define (alist->state alist)
  "把状态文件读出的 alist 还原成 <root-state>；缺键或类型不对即报错。"
  (define (required key)
    (let ((pair (assq key alist)))
      (unless pair
        (error "状态文件缺少字段" key))
      (cdr pair)))
  (define (integer-or-false key)
    (let ((value (required key)))
      (unless (or (not value) (integer? value))
        (error "状态文件字段应为整数或 #f" key value))
      value))
  (let ((next (required 'next-generation))
        (status (required 'boot-status)))
    (unless (and (integer? next) (>= next 0))
      (error "next-generation 应为非负整数" next))
    (unless (memq status '(first-boot trying ok))
      (error "boot-status 非法" status))
    (root-state (next-generation next)
                (current-generation (integer-or-false 'current-generation))
                (last-good-generation (integer-or-false 'last-good-generation))
                (created-at (or (assq-ref alist 'created-at) '()))
                (boot-status status)
                (source-template (or (assq-ref alist 'source-template)
                                     "@root-template"))
                (system-revision (assq-ref alist 'system-revision)))))

;;; ────────────────────────────────────────────────────────────
;;; 启动模式（docs/storage.md 第 17.6 节）。
;;; 通过内核命令行参数 rootmode= 选择，缺省为 normal：
;;;   rootmode=normal     从模板新建 generation（默认）
;;;   rootmode=keep       复用 current generation
;;;   rootmode=keep:3     复用指定的 @root-3
;;;   rootmode=recovery   回到 last-good generation

(define-record-type* <boot-mode>
                     boot-mode make-boot-mode
                     boot-mode?
                     (kind       boot-mode-kind)       ; normal / keep / recovery
                     (generation boot-mode-generation  ; keep:N 时为 N，否则 #f
                                 (default #f)))

(define %default-boot-mode (boot-mode (kind 'normal)))

(define (parse-boot-mode str)
  "解析 rootmode= 的参数值，返回 <boot-mode>；无法识别返回 #f。"
  (cond
    ((string=? str "normal")
     (boot-mode (kind 'normal)))
    ((string=? str "keep")
     (boot-mode (kind 'keep)))
    ((string=? str "recovery")
     (boot-mode (kind 'recovery)))
    ((string-prefix? "keep:" str)
     (let ((n (string->number (string-drop str 5))))
       (and (integer? n) (>= n 0)
            (boot-mode (kind 'keep) (generation n)))))
    (else #f)))

;;; ────────────────────────────────────────────────────────────
;;; 启动决策：给定当前状态与启动模式，产出一份“启动计划”。
;;; initrd 只负责执行计划：要不要从模板建快照、挂哪个子卷、状态改成什么。

(define-record-type* <boot-plan>
                     boot-plan make-boot-plan
                     boot-plan?
                     ;; 本次要挂载为根的子卷名，如 "@root-2"
                     (target-subvolume       boot-plan-target-subvolume)
                     ;; 为 #t 时先从事务创建该子卷：@root-N.new → @root-N
                     (create-from-template?  boot-plan-create-from-template?)
                     ;; 启动后应写回的状态（boot-status 一律置为 trying，
                     ;; 等用户态 confirm-boot 确认）
                     (state-after            boot-plan-state-after))

(define (plan-boot state mode now)
  "计算本次启动计划。NOW 是 Unix 时间，用于新建 generation 的 created-at。"
  (define (reuse-plan n)
    ;; 复用已存在的 @root-N：不建快照，只更新 current/boot-status。
    (unless n
      (error "没有可复用的 root generation"))
    (boot-plan (target-subvolume (root-generation-name n))
               (create-from-template? #f)
               (state-after
                (root-state
                 (inherit state)
                 (current-generation n)
                 (boot-status 'trying)))))
  (case (boot-mode-kind mode)
    ((recovery)
     (let ((last-good (root-state-last-good-generation state)))
       (unless last-good
         (error "没有可恢复的 last-good generation"))
       (reuse-plan last-good)))
    ((keep)
     (reuse-plan (or (boot-mode-generation mode)
                     (root-state-current-generation state))))
    ((normal)
     (if (eq? (root-state-boot-status state) 'first-boot)
       ;; 首次启动：直接用安装期建好的 @root-0（第 17.4 节）
       (reuse-plan (root-state-current-generation state))
       ;; 正常启动：从只读模板新建 @root-N（第 17.5 节）
       (let ((n (root-state-next-generation state)))
         (boot-plan
          (target-subvolume (root-generation-name n))
          (create-from-template? #t)
          (state-after
           (root-state
            (inherit state)
            (next-generation (+ n 1))
            (current-generation n)
            (created-at (cons `(,n . ,now)
                              (root-state-created-at state)))
            (boot-status 'trying)))))))
    (else
     (error "未知启动模式" (boot-mode-kind mode)))))

;;; ────────────────────────────────────────────────────────────
;;; 用户态确认：启动成功进入系统后，把 current 标记为 last-good。

(define (confirm-boot state)
  "启动健康检查通过后调用：current 提升为 last-good，状态置 ok（第 17.4 节）。"
  (root-state (inherit state)
              (last-good-generation (root-state-current-generation state))
              (boot-status 'ok)))

(define (prune-created-at state existing)
  "把 created-at 中已不存在于 EXISTING（磁盘上现存的 generation 编号
列表）的元数据清掉。由清理服务在删除旧 @root-N 后调用，
避免 created-at 随时间无限增长。"
  (root-state (inherit state)
              (created-at
               (filter (lambda (pair) (member (car pair) existing))
                       (root-state-created-at state)))))

;;; ────────────────────────────────────────────────────────────
;;; 清理（docs/storage.md 第 17.8 节）。
;;; 保留最新的 KEEP 个旧 generation，且绝不删除：
;;;   当前 generation、last-good generation。
;;; （recovery 引用的就是 last-good；事务中的 @root-N.new 不是合法
;;; generation 名，不会出现在 EXISTING 里，由执行层另行处理。）

(define (generations-to-delete existing state keep)
  "EXISTING 是磁盘上实际存在的 generation 编号列表。
返回应删除的编号列表（升序）。"
  (let* ((protected (delete #f (list (root-state-current-generation state)
                                     (root-state-last-good-generation state))))
         (candidates (lset-difference = existing protected))
         ;; 新的在前，保留前 KEEP 个，其余删除
         (sorted (sort candidates >)))
    (sort (drop sorted (min keep (length sorted))) <)))
