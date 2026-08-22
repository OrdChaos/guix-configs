;;; seed-once 原语：一次性初始化用户/应用状态的原子状态机。
;;;
;;; 语义（docs/architecture/persistence.md（seed-once））：
;;;   “只负责创建一个从未存在过的用户状态；创建成功后永久放弃
;;;   ownership。”绝不比较、merge、patch、同步或恢复默认。
;;;
;;; 状态记录：目标文件旁的 <target><%seed-marker-suffix> marker
;;; （空文件，presence = 状态）。每次调用检查：
;;;   marker 存在           → 'already-seeded：已提供过，永不重复
;;;                            （即使目标被 app/用户删除；删除 marker
;;;                            是显式重新 seed 的维护操作）
;;;   marker 缺失、目标存在 → 'preserved：已有数据（备份恢复/前次崩溃
;;;                            窗口），完全保留，补写 marker 固化
;;;                            “seed 决策已了结”
;;;   marker/目标均缺失     → 'seeded：原子写入 seed 内容，再写 marker
;;;
;;; 原子性（Case D：seed 中途失败不得留下被误判为已初始化的半成品）：
;;; 内容经 (guixcfg utils atomic-file) 的 .new → fsync → rename →
;;; fsync 父目录——目标路径只在完整内容落盘后出现。marker 写在 seed
;;; 之后：崩溃窗口下目标完整存在而 marker 缺失 → 下次走 'preserved
;;; 分支，只补 marker，不重复写、不覆盖。
;;;
;;; 本模块是纯机制，不知道具体应用；seed 内容/目标由上层（application
;;; persistence rule 的 seeds 字段）声明。运行在 activation gexp 内
;;; （root 身份），写出的文件 owner 由调用方负责（chown 到目标用户）。
;;; 只读依赖：Guile core + (guixcfg utils atomic-file) + (ice-9 rdelim)
;;; （read-string——已实测非 Guile core，AGENT.md §3 symbol audit）。

(define-module (guixcfg utils seed-once)
               #:use-module (guixcfg utils atomic-file) ; atomic-write-file!
               #:use-module (ice-9 rdelim)              ; read-string
               #:export (%seed-marker-suffix
                         seed-once-file!))

;; seed 生命周期 marker 后缀（每个 seed 目标一个 marker 文件）。
(define %seed-marker-suffix ".seed-provided")

(define (seed-once-file! dest source marker)
  "seed-once 单文件状态机。
DEST 目标绝对路径；SOURCE seed 源路径（store 中的 file-like 解析
结果）；MARKER 状态记录路径。
返回 symbol：'seeded（首次写入）/ 'preserved（已有数据，仅固化
marker）/ 'already-seeded（marker 已存在，未做任何事）。"
  (cond
    ((file-exists? marker)
     'already-seeded)
    ((file-exists? dest)
     ;; 已有数据：完全保留，不比较不覆盖；补写 marker 使 seed 决策
     ;; 一次性（否则每次 activation 都告警，且用户删掉数据后会被
     ;; 意外重新 seed）。
     (atomic-write-file! marker (lambda (port) #t))
     (format (current-error-port)
             "seed-once: ~a exists, preserving it (seed skipped; marker ~a)~%"
             dest marker)
     'preserved)
    (else
     (let ((content (call-with-input-file source
                                          (lambda (in) (read-string in)))))
       (atomic-write-file! dest (lambda (port) (display content port))))
     (atomic-write-file! marker (lambda (port) #t))
     'seeded)))
