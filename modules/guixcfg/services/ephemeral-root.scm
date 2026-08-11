;;; 无状态根的用户态服务（docs/storage.md 第 17 章）：
;;;
;;;   ephemeral-root-confirm   启动成功进入系统后，把 current 标记为
;;;                            last-good（boot-status: trying → ok）。
;;;                            这是第 17.4 节的“健康检查通过”；
;;;                            目前以 shepherd 启动到 user-processes
;;;                            为健康标准（见 one-shot-program-service）。
;;;   ephemeral-root-cleanup   按 host policy 的 keep-root-generations
;;;                            清理旧 @root-N（第 17.8 节），
;;;                            永不删除 current / last-good；
;;;                            顺带清理对应的 created-at 元数据。
;;;   状态文件一律经 (guixcfg storage root-generation) 的
;;;   read-state / write-state! 读写（原子写 + .prev 回退）。
;;;
;;; 启动时的选择/创建逻辑在 initrd 里（(guixcfg boot initrd)）；
;;; 状态机纯模型在 (guixcfg storage root-generation)，两侧共用。
;;;
;;; 实现注意：业务逻辑包在 program-file 生成的独立程序里——gexp 在
;;; 生成的程序文件中是顶层形式，use-modules 正常生效，且 program-file
;;; 自动写入 load-path 前导。不要直接把 (use-modules (guixcfg …))
;;; 塞进 shepherd-service 的 start lambda：嵌套的 use-modules 既不
;;; 参与宏展开，运行期导入的 module 也不对（lambda 的自由变量在
;;; 服务注册时的临时 module 里解析），会报 unbound variable。

(define-module (guixcfg services ephemeral-root)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage root-generation)
               #:use-module (gnu services)                 ; simple-service
               #:use-module (gnu services shepherd)        ; shepherd-service
               #:use-module (gnu packages linux)           ; btrfs-progs
               #:use-module (guix gexp)
               #:use-module (guix modules)                 ; source-module-closure
               #:export (ephemeral-root-shepherd-services))

;; 运行系统上 @persist-system 的挂载点（见 (guixcfg storage model)）。
(define %persist-system-mount "/persist/system")

;; 清理时临时挂载 Btrfs 顶层的位置。
(define %btrfs-top-mount "/run/guixcfg-btrfs-top")

;; source-module-closure 的默认 select? 只收 (guix …)/(gnu …) 模块，
;; (guixcfg …) 会被静默过滤导致运行期 no code for module，必须自定义。
(define (guixcfg-module-select? name)
  (or (guix-module-name? name)
      (eq? (car name) 'guixcfg)))

(define (ephemeral-root-confirm-program)
  (program-file
   "ephemeral-root-confirm"
   (with-imported-modules
    (source-module-closure '((guixcfg storage root-generation)
                             (guixcfg boot boot-state))
                           #:select? guixcfg-module-select?)
    #~(begin
       (use-modules (guixcfg storage root-generation)
                    (guixcfg boot boot-state))
       (let ((path (state-file-path #$%persist-system-mount)))
         (when (file-exists? path)
           (let ((state (read-state path)))
             (when (eq? (root-state-boot-status state) 'trying)
               (write-state! path (confirm-boot state))
               (format #t "ephemeral-root: @root-~a 已确认为 last-good~%"
                       (root-state-current-generation state))))))
       ;; 部署成功 ≠ 启动成功：这里才是真正的“启动确认”——
       ;; 把当前系统登记为 Boot State 的 last-good（Guix 轴），
       ;; 供下次部署生成 RECOVERY.EFI 的 Guix 轴（见 (guixcfg boot uki)）。
       (let ((n (current-system-generation)))
         (if n
           (begin
            (write-boot-states! %boot-states-path
                                n
                                (current-kernel-command-line))
            (format #t "boot-state: Guix generation ~a 已确认为 last-good~%"
                    n))
           (format #t "boot-state: 无法确定当前 Guix generation，跳过~%")))))))

(define (ephemeral-root-cleanup-program keep)
  "KEEP 是保留的旧 root generation 数量（host policy）。"
  (program-file
   "ephemeral-root-cleanup"
   (with-imported-modules
    (source-module-closure '((guixcfg storage root-generation)
                             (guix build syscalls)  ; mount、umount
                             (guix build utils))   ; mkdir-p
                           #:select? guixcfg-module-select?)
    #~(begin
       (use-modules (guixcfg storage root-generation)
                    (guixcfg storage model)
                    (guix build syscalls)
                    ((guix build utils) #:hide (delete))  ; mkdir-p
                    (srfi srfi-1)       ; filter-map
                    (ice-9 ftw))        ; scandir（不在 Guile core，在 ftw 里）
       (let ((state-path (state-file-path #$%persist-system-mount))
             (top #$%btrfs-top-mount)
             (mapper #$(string-append "/dev/mapper/" %luks-mapper-name))
             (btrfs (string-append #$btrfs-progs "/bin/btrfs")))
         (if (not (file-exists? state-path))
           (format #t "ephemeral-root: 状态文件不存在，跳过清理~%")
           (let ((state (read-state state-path)))
             (let ((mounted? #f))
               (dynamic-wind
                 (lambda ()
                   (mkdir-p top)
                   (mount mapper top "btrfs" 0 "subvolid=5")
                   (set! mounted? #t))
                 (lambda ()
                   (let* ((names (or (scandir top) '()))
                          (existing (filter-map parse-root-generation names))
                          (victims (generations-to-delete existing state
                                                          #$keep)))
                     ;; invoke 在任意删除失败时立即抛错；只有全部成功后才
                     ;; prune metadata，状态不会谎称仍存在的子卷已被删除。
                     (for-each
                      (lambda (n)
                        (format #t "ephemeral-root: 删除旧 generation ~a~%"
                                (root-generation-name n))
                        (invoke btrfs "subvolume" "delete"
                                (string-append top "/"
                                               (root-generation-name n))))
                      victims)
                     (let ((remaining (lset-difference = existing victims)))
                       (write-state! state-path
                                     (prune-created-at state remaining)))))
                 (lambda ()
                   (when mounted?
                     (umount top))))))))))))

(define* (one-shot-program-service name program documentation
                                   #:key (requirement '(user-processes)))
         "运行 PROGRAM 一次的 shepherd 服务。"
         (shepherd-service
          (provision (list name))
          ;; 健康门槛（docs/storage.md 第 17.4 节）：不能只依赖 file-systems
          ;; ——那时网络/显示管理器等关键服务还没起，过早把 current 标成
          ;; last-good 会让“上次能启动”失去意义。user-processes 是
          ;; shepherd 启动顺序中较晚的锚点；更精细的健康检查
          ;; （关键服务状态、会话可用）随桌面阶段再细化。
          (requirement requirement)
          (one-shot? #t)
          (documentation documentation)
          (start #~(lambda () (zero? (system* #$program))))
          (stop #~(const #f))))

(define (ephemeral-root-shepherd-services keep)
  "无状态根的全部用户态服务。KEEP 是保留的旧 generation 数量。
shepherd-service 记录经 simple-service 挂到 shepherd-root-service-type，
才能放进 <operating-system> 的 services 字段。"
  (list (simple-service 'ephemeral-root-confirm
                        shepherd-root-service-type
                        (list (one-shot-program-service
                               'ephemeral-root-confirm
                               (ephemeral-root-confirm-program)
                               "Mark the current root generation as last-good \
after a successful boot.")))
        (simple-service 'ephemeral-root-cleanup
                        shepherd-root-service-type
                        (list (one-shot-program-service
                               'ephemeral-root-cleanup
                               (ephemeral-root-cleanup-program keep)
                               "Delete old @root-N subvolumes beyond the \
configured retention."
                               ;; 状态文件是 read-modify-write，必须排在
                               ;; confirm 之后，否则两个服务并发读写会
                               ;; 互相覆盖（cleanup 的旧状态会抹掉
                               ;; confirm 刚写入的 last-good）。
                               #:requirement '(user-processes
                                               ephemeral-root-confirm))))))
