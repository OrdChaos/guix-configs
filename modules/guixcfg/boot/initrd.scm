;;; 无状态根 initrd：启动时在 initrd 里选择/创建本次的 root generation。
;;; 对应 docs/storage.md 第 17 章。
;;;
;;; 为什么不能直接给 raw-initrd 传 #:pre-mount（尝试过，不可行）：
;;;   1. raw-initrd 把用户 pre-mount 排在 mapped-devices 解锁之前，
;;;      而我们必须先解锁 LUKS 才能读 Btrfs 里的状态文件；
;;;   2. LUKS 的 open gexp 用到 (ice-9 match) 等宏，Guile 只在
;;;      init 文件的顶层 use-modules 展开宏（嵌套的不生效），
;;;      而顶层 use-modules 由 raw-initrd 内部生成、无法注入。
;;; 因此这里照 raw-initrd 的骨架（gnu/system/linux-initrd.scm）写自己的
;;; init 构建器，把 mapped-device 所需模块放进顶层 use-modules，
;;; 并按「解锁 LUKS → 选/建 @root-N → 交给 boot-system」的顺序组织
;;; pre-mount。上游 raw-initrd 变化时需跟进此处。
;;;
;;; 选卷逻辑复用纯模型 (guixcfg storage root-generation)（由
;;; with-imported-modules 带进 initrd），行为由
;;; tests/test-root-generation.scm 覆盖。

(define-module (guixcfg boot initrd)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage root-generation)
               #:use-module (gnu system linux-initrd)      ; expression->initrd、flat-linux-module-directory
               #:use-module (gnu system mapped-devices)    ; mapped-device-kind-open
               #:use-module (gnu system file-systems)      ; file-system->spec
               #:use-module (gnu packages linux)           ; btrfs-progs/static
               #:use-module (guix gexp)
               #:use-module (guix modules)                 ; source-module-closure
               #:use-module (srfi srfi-1)                  ; append-map
               #:export (%staging-root-path
                         ephemeral-root-initrd))

;; initrd 里选中子卷的挂载点；os 的根 file-system 声明为对它的 bind-mount。
(define %staging-root-path "/selected-root")

;; initrd 里 Btrfs 顶层（subvolid=5）的临时挂载点。
(define %btrfs-top-path "/btrfs-top")

(define (mapped-device-open-commands mapped-devices)
  "与 raw-initrd 相同的方式生成 mapped-devices 的 open gexp 列表
（含 LUKS 密码询问与 GRUB master-key 透传）。"
  (map (lambda (md)
         (let* ((source  (mapped-device-source md))
                (targets (mapped-device-targets md))
                (type    (mapped-device-type md))
                (open    (mapped-device-kind-open type)))
           (apply open source targets
             (mapped-device-arguments md))))
       mapped-devices))

(define select-root-gexp
  ;; 在 LUKS 解锁之后执行：读状态 → plan-boot 决策 → 必要时从模板
  ;; 事务创建 @root-N → 写回状态 → 挂到 staging。
  ;; 用到的模块都在 init 顶层 use-modules 里（宏展开只对顶层生效）。
  #~(begin
     (let* ((top      #$%btrfs-top-path)
            (staging  #$%staging-root-path)
            (mapper   #$(string-append "/dev/mapper/" %luks-mapper-name))
            (btrfs    (string-append #$btrfs-progs/static "/bin/btrfs"))
            (state-path
             (state-file-path (string-append top "/@persist-system"))))
       
       (define (btrfs-run . args)
         (unless (zero? (apply system* btrfs args))
           (error "btrfs 命令失败" args)))
       
       ;; 1. 挂顶层，读状态（主文件损坏时 read-state 自动回退 .prev）
       (mkdir-p top)
       (mount mapper top "btrfs" 0 "subvolid=5")
       (unless (file-exists? state-path)
         (error "root generation 状态文件不存在" state-path))
       (let* ((state (read-state state-path))
              ;; 2. 启动模式：rootmode=normal/keep[:N]/previous:K/recovery
              (raw-mode (or (and=> (find-long-option "rootmode"
                                                     (linux-command-line))
                                   (lambda (s)
                                     (or (parse-boot-mode s)
                                         (error "无法识别的 rootmode" s))))
                            %default-boot-mode))
              ;; previous:K 是运行期相对选择器（历史启动菜单），
              ;; 从顶层目录的现存 generation 解析成具体编号，
              ;; 再按 keep:N 走——部署期的菜单因此永不过期。
              (mode  (if (eq? (boot-mode-kind raw-mode) 'previous)
                       (boot-mode
                        (kind 'keep)
                        (generation
                         (or (previous-generation
                              (filter-map parse-root-generation
                                          (scandir top))
                              (boot-mode-generation raw-mode))
                             (error "没有足够的历史 root generation"
                                    (boot-mode-generation raw-mode)))))
                       raw-mode))
              (plan   (plan-boot state mode (current-time)))
              (target (boot-plan-target-subvolume plan)))
         
         (format #t "root generation: ~a（模式 ~a）~%"
                 target (boot-mode-kind mode))
         
         ;; 3. Normal：从事务创建 @root-N（先清残留，再快照，再改名）
         (when (boot-plan-create-from-template? plan)
           (let ((new-path   (string-append top "/" target ".new"))
                 (final-path (string-append top "/" target)))
             (when (file-exists? new-path)
               (format #t "清理上次事务残留的 ~a~%" new-path)
               (btrfs-run "subvolume" "delete" new-path))
             (when (file-exists? final-path)
               ;; 上次在改名后、写状态前崩溃：该 generation 从未被
               ;; 记录为已启动，删掉重建是安全的。
               (format #t "清理未记录的 ~a~%" final-path)
               (btrfs-run "subvolume" "delete" final-path))
             (btrfs-run "subvolume" "snapshot"
                        (string-append top "/"
                                       (root-state-source-template state))
                        new-path)
             (rename-file new-path final-path)))
         
         ;; 4. 先把选中子卷挂到 staging——只有目标确实存在且可挂载，
         ;;    事务才允许继续（比如 rootmode=keep:999 在这里就会失败，
         ;;    而不会先把 current=999 写进状态再死）。
         (mkdir-p staging)
         (mount mapper staging "btrfs" 0
                (string-append "subvol=" target))
         
         ;; 5. 状态提交是本次 root 选择事务的最后一步（原子写）。
         (write-state! state-path (boot-plan-state-after plan))
         
         ;; 6. 收顶层
         (umount top)
         #t))))

(define* (ephemeral-root-initrd file-systems
                                #:key
                                linux
                                (linux-modules '())
                                (mapped-devices '())
                                (keyboard-layout #f)
                                (on-error 'debug)
                                #:allow-other-keys)
         "<operating-system> 的 initrd 构建器（替换 base-initrd）。
调用约定由 operating-system-initrd-file 决定。
注意：KEYBOARD-LAYOUT 被忽略——initrd 使用内核默认控制台布局
（US），输入 ASCII LUKS 密码不受影响。"
         (define device-mapping-commands
           (mapped-device-open-commands mapped-devices))
         
         ;; 与 base-initrd 相同：操作系统传入的 initrd-modules（默认
         ;; %base-initrd-modules）只是基础驱动，文件系统自身的模块
         ;; （我们的根类型是 "none"，btrfs 必须从持久子卷的声明里派生，
         ;; 否则 initrd 里挂 Btrfs 顶层会 ENODEV）。
         (define linux-modules*
           `(,@linux-modules
               ,@(file-system-modules file-systems)))
         
         (define file-system-scan-commands
           ;; 与 raw-initrd 相同：btrfs 文件系统需要 device scan 组装多设备卷
           ;; （单盘 LUKS 场景下无害）。
           (let ((file-system-types (map file-system-type file-systems)))
             (if (member "btrfs" file-system-types)
               #~((system* (string-append #$btrfs-progs/static "/bin/btrfs")
                           "device" "scan"))
               #~())))
         
         (define kodir
           ;; flat-linux-module-directory 未从 (gnu system linux-initrd) 导出，
           ;; 用 @@ 取私有绑定；上游若改名需跟进。
           ((@@ (gnu system linux-initrd) flat-linux-module-directory)
            linux linux-modules*))
         
         (expression->initrd
          (with-imported-modules
           ;; raw-initrd 的模块集 + 我们的纯模型（其闭包含
           ;; (guixcfg storage model) 与 (guix records)）。
           ;; 注意 source-module-closure 的默认 select? 只收 (guix …)/(gnu …)
           ;; 模块，(guixcfg …) 会被过滤掉，必须自定义。
           (source-module-closure '((gnu build linux-boot)
                                    (guix build utils)
                                    (guix build bournish)
                                    (gnu system file-systems)
                                    (gnu build file-systems)
                                    (guix build syscalls)
                                    (guixcfg storage root-generation))
                                  #:select? (lambda (name)
                                              (or (guix-module-name? name)
                                                  (eq? (car name) 'guixcfg))))
           #~(begin
              ;; 顶层 use-modules：宏（如 LUKS open gexp 里的 match）
              ;; 只在顶层展开生效，mapped-device 所需模块必须列在这里。
              (use-modules (gnu build linux-boot)
                           (gnu system file-systems)
                           ((guix build utils) #:hide (delete))
                           (guix build bournish)   ; bournish meta-command（REPL 调试用）
                           (guix build syscalls)   ; mount、umount
                           (srfi srfi-1)
                           (srfi srfi-26)
                           (ice-9 ftw)              ; scandir（previous:K 解析）
                           (guixcfg storage root-generation)
                           (guixcfg storage model)  ; parse-root-generation
                           #$@(append-map (lambda (md)
                                            (mapped-device-kind-modules
                                             (mapped-device-type md)))
                                          mapped-devices))
              
              (parameterize ((current-warning-port (%make-void-port "w")))
                            (boot-system #:mounts
                                         (map spec->file-system
                                              '#$(map file-system->spec file-systems))
                                         ;; 顺序关键：先解锁 LUKS，再按状态选/建
                                         ;; root generation，最后 btrfs device scan。
                                         #:pre-mount (lambda ()
                                                       (and #$@device-mapping-commands
                                                            #$select-root-gexp
                                                            #$@file-system-scan-commands))
                                         #:linux-modules '#$linux-modules*
                                         #:linux-module-directory '#$kodir
                                         #:keymap-file #f
                                         #:qemu-guest-networking? #f
                                         #:volatile-root? #f
                                         #:on-error '#$on-error))))
          #:name "raw-initrd"))
