;;; Boot State 注册表：记录“最后一次确认启动成功”的 Guix system
;;; generation、system store identity 与当次实际 kernel command line。
;;; system store path 是权威 identity；generation 编号是 profile/human
;;; identity。
;;;
;;; 角色：confirm 时的最终 commit record + LiveCD 人工救援的审计输入
;;; （docs/operations/recovery.md）。部署成功 ≠ 启动成功——注册表只在
;;; 用户态确认（services/ephemeral-root 的 confirm）之后更新，不由部署
;;; 流程更新。没有部署期程序化读者：Recovery artifact 由部署脚本从
;;; 【当前 deployment】构建（rootmode=recovery），confirm 时经
;;; (guixcfg boot recovery) promote，不从本注册表解析。
;;;
;;; 同时维护 last-good 的 Guix GC root（/var/guix/gcroots/guixcfg/），
;;; 保证 guix gc / delete-generations 不会回收正式 Recovery 的 closure。
;;;
;;; 与 root generation 状态（storage/root-generation.scm）的分工：
;;;   root-generations/state.scm   → 哪个 @root-N 可回退（Btrfs 轴）
;;;   boot-states.scm              → 哪个 Guix system 可回退（声明式系统轴）
;;; 两轴正交。Recovery 有意把两个轴各自最近确认值组合起来；它是人工
;;; 救援入口，不把这对组合提升为正常启动可见的稳定状态。

(define-module (guixcfg boot boot-state)
               #:use-module (guixcfg utils atomic-file)
               #:use-module (guixcfg storage model)  ; persist-mount-point（/persist 语义路径 authority）
               #:use-module (guix build utils)   ; mkdir-p
               #:use-module (ice-9 ftw)      ; scandir
               #:use-module (ice-9 regex)    ; string-match
               #:use-module (ice-9 rdelim)   ; read-line
               #:use-module (srfi srfi-1)    ; filter
               #:use-module (srfi srfi-13)   ; string-tokenize/string-join
               #:export (%boot-states-path
                         read-boot-state-alist
                         write-boot-states!
                         protect-last-good!
                         current-kernel-command-line
                         current-system-generation))

;; 注册表位置（运行系统视角；initrd 不涉及）。
(define %boot-states-path
  (string-append (persist-mount-point "@persist-system") "/boot-states.scm"))

;;; ────────────────────────────────────────────────────────────
;;; crash-durable 读写：先把能够成功解析的旧状态原子写入 .prev，再把
;;; .new → fsync → rename 为主文件并 fsync 父目录。损坏主文件不会污染 .prev。

;; last-good 的 Guix GC root（confirmed system 不被 GC 回收）。
(define* (protect-last-good! system #:key (root "/var/guix/gcroots/guixcfg")
                             (name "last-good-system"))
         "把 CONFIRMED 的 SYSTEM 挂到 GC root（原子 symlink 替换）。"
         (let ((dir (string-append root "/" name)))
           (mkdir-p root)
           (let ((tmp (string-append dir ".new"))
                 (target (string-append root "/" name)))
             (false-if-exception (delete-file tmp))
             (symlink system tmp)
             (rename-file tmp target)
             (format #t "gc-root: ~a -> ~a~%" target system))))

(define* (write-boot-states! path generation command-line
                             #:key (system #f))
         "记录 LAST-GOOD Guix profile generation、SYSTEM store identity 与当次
实际 COMMAND-LINE（已去除 rootmode=）。格式 v2；SYSTEM 是可选的
identity 字段（生产调用方总是提供）。"
         (let ((last-good `((generation . ,generation)
                            ,@(if system `((system . ,system)) '())
                             (command-line . ,command-line))))
           (let ((previous (and (or (file-exists? path)
                                    (file-exists? (string-append path ".prev")))
                                (false-if-exception (read-boot-state-alist path)))))
             (when previous
               (atomic-write-file! (string-append path ".prev")
                                   (lambda (port)
                                     (write previous port)
                                     (newline port))))
             (atomic-write-file! path
                                 (lambda (port)
                                   (write `((format-version . 2)
                                            (last-good . ,last-good))
                                          port)
                                   (newline port))))))

(define (read-boot-state-alist path)
  "读取注册表 alist。兼容 v1（((last-good . N) (command-line . C))）与
v2（((format-version . 2) (last-good . ((generation . N) (system . S)
(command-line . C))))）——v1 只剩历史机器上的存量文件，写入端总是
v2。主文件损坏或缺失时回退 .prev。"
  (define (try p)
    (let* ((state (call-with-input-file p read))
           (last-good (and (list? state) (assq-ref state 'last-good)))
           (command-line (and (list? state) (assq-ref state 'command-line))))
      (unless (and (list? state)
                   (assq 'last-good state)
                   (or (not last-good)
                       (integer? last-good)
                       (and (list? last-good) (assq 'generation last-good)))
                   (or (not command-line) (string? command-line)))
        (error "malformed boot-state" p state))
      state))
  (if (file-exists? path)
    (catch #t
      (lambda () (try path))
      (lambda (key . args)
        (let ((prev (string-append path ".prev")))
          (if (file-exists? prev)
            (try prev)
            (apply throw key args)))))
    (let ((prev (string-append path ".prev")))
      (and (file-exists? prev) (try prev)))))

(define (current-kernel-command-line)
  "读取 /proc/cmdline，并去掉 rootmode= 参数。
rootmode 属于本项目菜单选择语义，不应固化进 Guix generation 的
last-good 启动参数；Recovery 会显式追加 rootmode=recovery。"
  (call-with-input-file "/proc/cmdline"
                        (lambda (port)
                          (let ((line (read-line port)))
                            (and (string? line)
                                 (string-join
                                  (filter (lambda (arg)
                                            (not (string-prefix? "rootmode=" arg)))
                                          (string-tokenize line))
                                  " "))))))

(define (current-system-generation)
  "返回当前运行系统对应的 Guix profile generation 编号（或 #f）。
方法：/run/current-system 的解析路径与 profiles/system-N-link 逐一比对。"
  (let ((current (false-if-exception (canonicalize-path "/run/current-system")))
        (profiles "/var/guix/profiles"))
    (and current
         (let loop ((names (or (scandir profiles) '())))
           (and (not (null? names))
                (let* ((name (car names))
                       (m (string-match "^system-([0-9]+)-link$" name)))
                  (if (and m
                           (equal? current
                                   (false-if-exception
                                    (canonicalize-path
                                     (string-append profiles "/" name)))))
                    (string->number (match:substring m 1))
                    (loop (cdr names)))))))))
