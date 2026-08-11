;;; Boot State 注册表：记录“最后一次确认启动成功”的 Guix system
;;; generation（Current/Last Good 菜单语义的数据源）。
;;;
;;; 与 root generation 状态（storage/root-generation.scm）的分工：
;;;   root-generations/state.scm   → 哪个 @root-N 可回退（Btrfs 轴）
;;;   boot-states.scm              → 哪个 Guix system 可回退（声明式系统轴）
;;; 两轴正交（docs/storage.md 第 18 章）。
;;;
;;; 语义关键：部署成功 ≠ 启动成功。注册表只在用户态确认
;;; （services/ephemeral-root 的 confirm，见 docs/storage.md 17.4）
;;; 之后更新，不由部署流程更新。
;;;
;;; 注册表只保存 Guix profile generation 编号——
;;; /var/guix/profiles/system-N-link 本身就是 Guix 维护的 GC root，
;;; kernel/initrd/cmdline 都能从它解析，不需要复制任何路径。

(define-module (guixcfg boot boot-state)
               #:use-module (guix records)
               #:use-module (ice-9 ftw)      ; scandir
               #:use-module (ice-9 regex)    ; string-match
               #:export (%boot-states-path
                         read-boot-states
                         write-boot-states!
                         boot-states-last-good
                         resolve-generation
                         current-system-generation))

;; 注册表位置（运行系统视角；initrd 不涉及）。
(define %boot-states-path "/persist/system/boot-states.scm")

;;; ────────────────────────────────────────────────────────────
;;; 原子读写（与 root-generation 的 state.scm 同一模式：
;;; 写 .new → fsync → rename；读取时主文件损坏回退 .prev）。

(define (write-boot-states! path last-good)
  "LAST-GOOD 是 Guix profile generation 编号（整数）或 #f。"
  (let ((new  (string-append path ".new"))
        (prev (string-append path ".prev")))
    (when (file-exists? path)
      (copy-file path prev))
    (call-with-output-file new
                           (lambda (port)
                             (write `((last-good . ,last-good)) port)
                             (newline port)
                             (fsync port)))
    (rename-file new path)))

(define (read-boot-states path)
  "读取注册表，返回 last-good 编号或 #f。文件不存在或损坏均视为 #f。"
  (define (try p)
    (assq-ref (call-with-input-file p read) 'last-good))
  (if (file-exists? path)
    (catch #t
      (lambda () (try path))
      (lambda (key . args)
        (let ((prev (string-append path ".prev")))
          (and (file-exists? prev) (try prev)))))
    #f))

;;; ────────────────────────────────────────────────────────────
;;; generation 编号 → 可部署条目。

(define (resolve-generation mount number)
  "把 Guix profile generation NUMBER 解析成可构建 UKI 的条目：
(list system-path kernel initrd cmdline)。MOUNT 是系统根挂载点
（运行时为 \"\"，init 时为 \"/mnt\"）。解析失败返回 #f。"
  (and number
       (let* ((link (string-append mount "/var/guix/profiles/system-"
                                   (number->string number) "-link"))
              (system (false-if-exception (canonicalize-path link))))
         (and system
              (let ((kernel (string-append system "/kernel/bzImage"))
                    (initrd (string-append system "/initrd")))
                (and (file-exists? kernel)
                     (file-exists? initrd)
                     (list system
                           kernel
                           initrd
                           (string-append
                            "root=/selected-root gnu.system=" system
                            " gnu.load=" system "/boot"))))))))

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
