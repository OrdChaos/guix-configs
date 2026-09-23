;;; System generation 删除执行入口（tooling plane，pinned 环境）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/gc-cli.scm -- plan HOST [--keep N | --delete LIST]
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/gc-cli.scm -- run  HOST [--keep N | --delete LIST]
;;;
;;; plan 只读（显示将删除的 generation）；run 执行
;;; `guix package -p <system-profile> --delete-generations=...`。
;;; **不运行 `guix gc`**：删除 profile generation 只是移除 GC root，
;;; 不释放 store 空间；自动 `guix gc` 会连带回收 on-demand store 内容
;;; （如 guix-rust-toolchain 代理 realize 的 toolchain）。store 回收由
;;; 操作者显式执行。域逻辑在 (guixcfg system system-generations)；本脚本
;;; 只做 argv 解析与子进程执行（blueprint 编译期不导入该模块——gsettings/
;;; install/enroll 同款决策）。
;;;
;;; 需要 root（写 /var/guix/profiles）。blue gc 经 sudo 直接以 root
;;; 运行本工具的 run；plan 可普通用户运行（只读）。
;;;
;;; 退出码：0 成功；1 参数/执行失败（fail closed）。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg system system-generations)
             (guix build utils)          ; invoke
             (ice-9 match)
             (ice-9 format)
             (srfi srfi-13))

(define (usage)
  (format (current-error-port)
          "Usage: guix time-machine -C channels.lock.scm -- repl ~
tools/gc-cli.scm -- ACTION HOST [--keep N | --delete LIST]~%actions: plan | run~%")
  (exit 1))

(define (parse-options args)
  "解析 [--keep N | --delete LIST]，返回 (values keep delete)。
两者互斥；--keep 必须是整数；--delete 走 parse-generation-list。"
  (let loop ((args args) (keep #f) (delete #f))
    (match args
           (() (values keep delete))
           (("--keep" n . rest)
            (when keep (usage))
            (let ((k (string->number n)))
              (unless (and k (integer? k) (>= k 0))
                (error "--keep requires a non-negative integer" n))
              (loop rest k delete)))
           (("--delete" list . rest)
            (when delete (usage))
            (loop rest keep (parse-generation-list list)))
           (_ (usage)))))

(define (exception-strings exn-args)
  "从 catch 的 (key . args) 里递归提取全部字符串/符号（对 misc-error
内部布局不敏感），供单行错误输出。"
  (let walk ((x exn-args))
    (cond ((string? x) (list x))
      ((symbol? x) (list (symbol->string x)))
      ((pair? x) (append (walk (car x)) (walk (cdr x))))
      (else '()))))

(define (error-text key args)
  "把 catch 的 (key . args) 收敛为单行错误文本。misc-error 的 args 是
(#f FORMAT (MESSAGE . IRRITANTS) #f)——直接取 MESSAGE/IRRITANTS，
避免把内部 FORMAT（\"~A ~S\"）混进输出。"
  (if (and (eq? key 'misc-error)
           (>= (length args) 3)
           (list? (caddr args)))
    (string-join (map (lambda (x) (if (string? x) x (object->string x)))
                      (caddr args))
                 " ")
    (string-join (exception-strings args) " ")))

(define (display-list numbers)
  (if (null? numbers)
    "(none)"
    (string-join (map number->string numbers) " ")))

(define (print-plan plan)
  (let ((existing (assq-ref plan 'existing))
        (current (assq-ref plan 'current))
        (last-good (assq-ref plan 'last-good))
        (mode (assq-ref plan 'mode))
        (keep (assq-ref plan 'keep))
        (to-delete (assq-ref plan 'to-delete)))
    (format #t "system generation reclamation plan~%")
    (format #t "  existing:   ~a~%" (display-list existing))
    (format #t "  current:    ~a~%" (or current "(unknown)"))
    (format #t "  last-good:  ~a~%" (or last-good "(none)"))
    (format #t "  mode:       ~a~%" mode)
    (when (eq? mode 'keep)
      (format #t "  keep:       ~a (protected + newest)~%" keep))
    (format #t "  to delete:  ~a~%" (display-list to-delete))))

(define (run! plan)
  (let ((to-delete (assq-ref plan 'to-delete)))
    (if (null? to-delete)
      (format #t "no system generation to delete~%")
      (begin
       (format #t "deleting system generation(s): ~a~%"
               (display-list to-delete))
       (apply invoke (delete-generations-argv %system-profile to-delete))))))

(define (main args)
  (when (and (pair? args)
             (string=? (car args) "run")
             (not (zero? (getuid))))
    (format (current-error-port)
            "gc transaction requires root (effective UID 0)~%")
    (exit 1))
  (catch #t
    (lambda ()
      (match args
             ((mode host . rest)
              (unless (member mode '("plan" "run"))
                (usage))
              (call-with-values (lambda () (parse-options rest))
                                (lambda (keep delete)
                                  (let ((plan (system-generation-plan
                                               #:host host #:keep keep #:delete delete)))
                                    (print-plan plan)
                                    (when (string=? mode "run")
                                      (run! plan))))))
             (_ (usage))))
    (lambda (key . args)
      (format (current-error-port) "gc: ~a~%" (error-text key args))
      (exit 1))))

(main (cdr (command-line)))
