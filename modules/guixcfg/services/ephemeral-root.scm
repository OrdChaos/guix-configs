;;; 无状态根的用户态服务（docs/architecture/storage.md）：
;;;
;;;   ephemeral-root-confirm   把 current 标记为 last-good
;;;                            （boot-status: trying → ok）并 promote
;;;                            Guix 轴（Recovery candidate → 稳定路径 +
;;;                            boot-state commit record + GC root）。
;;;                            **触发点 = greetd PAM session open**
;;;                            （首次成功交互式图形登录之后），不再是
;;;                            shepherd user-processes——"部署成功 ≠
;;;                            启动成功 ≠ 登录可用"：boot 到
;;;                            user-processes 只证明内核与服务起来，
;;;                            不证明登录链可用（readiness gate 不开、
;;;                            greetd 起不来、PAM/account 断裂时，
;;;                            user-processes 照样到，但系统不可用）。
;;;                            登录链断裂时 current 保持 trying，
;;;                            不污染 last-good。
;;;   ephemeral-root-cleanup   按 host policy 的 keep-root-generations
;;;                            清理旧 @root-N，永不删除 current /
;;;                            last-good；顺带清理对应的 created-at
;;;                            元数据。
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
               #:use-module (guixcfg boot layout)         ; %esp-mount-point
               #:use-module (guixcfg utils module-closure) ; guixcfg-module-select?
               #:use-module (gnu services)                 ; simple-service
               #:use-module (gnu services shepherd)        ; shepherd-service
               #:use-module (gnu system pam)  ; pam-root-service-type、pam-extension、pam-entry
               #:use-module (gnu packages linux)           ; btrfs-progs
               #:use-module (guix gexp)
               #:use-module (guix modules)                 ; source-module-closure
               #:export (ephemeral-root-services
                         ephemeral-root-confirm-program)) ; 测试需要真实执行

;; 运行系统上 @persist-system 的挂载点（单一 authority：
;; (guixcfg storage model) 的 persist-mount-point——禁止重复 literal）。
(define %persist-system-mount (persist-mount-point "@persist-system"))

;; 清理时临时挂载 Btrfs 顶层的位置。
(define %btrfs-top-mount "/run/guixcfg-btrfs-top")

(define (ephemeral-root-confirm-program)
  "confirm 程序：root-state trying→ok + Guix 轴 promote。由 greetd
PAM session hook 携带 PAM_TYPE=open_session 调用（pam_exec 在
close_session 也会执行——门在程序内）。也可人工直接调用（无
PAM_TYPE 时正常工作）。幂等：boot-state 已记录当前 generation 为
last-good 时跳过 promote——登录路径每次图形登录都会触发本程序，
不能每次重写 ESP/boot-state。"
  (program-file
   "ephemeral-root-confirm"
   (with-imported-modules
    (source-module-closure '((guixcfg storage root-generation)
                             (guixcfg boot boot-state)
                             (guixcfg boot recovery))
                           #:select? guixcfg-module-select?)
    #~(begin
       (use-modules (guixcfg storage root-generation)
                    (guixcfg boot boot-state)
                    (guixcfg boot recovery))
       ;; pam_exec 在 open_session 与 close_session 都会调用本程序
       ;; （PAM_TYPE 环境变量区分）——只在 open 时工作。无 PAM_TYPE
       ;; = 人工/测试直接调用。
       (let ((pam-type (getenv "PAM_TYPE")))
         (when (and pam-type (not (string=? pam-type "open_session")))
           (exit 0)))
       ;; Btrfs 轴：current root generation → last-good。
       (let ((path (state-file-path #$%persist-system-mount)))
         (when (file-exists? path)
           (let ((state (read-state path)))
             (when (eq? (root-state-boot-status state) 'trying)
               (write-state! path (confirm-boot state))
               (format #t "ephemeral-root: @root-~a confirmed as last-good~%"
                       (root-state-current-generation state))))))
       ;; Guix 轴：boot-state 注册表记录的 last-good generation
       ;; （v2 alist / v1 整数兼容；缺失为 #f）。
       (define (recorded-last-good-generation)
         (let ((alist (read-boot-state-alist %boot-states-path)))
           (and alist
                (let ((lg (assq-ref alist 'last-good)))
                  (if (and (list? lg) (assq 'generation lg))
                      (assq-ref lg 'generation)
                      lg)))))
       ;; 部署成功 ≠ 启动成功 ≠ 登录可用：promote Recovery
       ;; candidate（验证 identity → GC root → artifact → 菜单）并
       ;; 记录 Boot State 的 last-good（Guix 轴，最终 commit）。
       (let ((n (current-system-generation)))
         (cond
          ((not n)
           (format #t "boot-state: cannot determine current Guix generation; skipping~%"))
          ((equal? n (recorded-last-good-generation))
           (format #t "boot-state: Guix generation ~a already last-good; skipping~%" n))
          (else
           (promote-recovery! #$%esp-mount-point n (current-kernel-command-line))
           (format #t "boot-state: Guix generation ~a confirmed as last-good~%" n))))))))

(define (ephemeral-root-cleanup-program keep)
  "KEEP 是保留的旧 root generation 数量（host policy）。"
  (program-file
   "ephemeral-root-cleanup"
   ;; closure seeds 与 runtime use-modules 对应：srfi-1（filter-map）显式
   ;; 列出，不依赖 guix build utils 传递；ice-9 ftw 为 guile 自带模块。
   (with-imported-modules
    (source-module-closure '((guixcfg storage root-generation)
                             (guix build syscalls)  ; mount、umount
                             (guix build utils)   ; mkdir-p
                             (srfi srfi-1))      ; filter-map
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
             (mapper #$%luks-mapper-path)
             (btrfs (string-append #$btrfs-progs "/bin/btrfs")))
         (if (not (file-exists? state-path))
           (format #t "ephemeral-root: state file missing; skipping cleanup~%")
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
                       (format #t "ephemeral-root: deleting old generation ~a~%"
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

;; greetd PAM session hook：成功图形登录后才确认 last-good。
;; pam-extension transformer（login-gate 同款横切机制）只作用
;; "greetd"——login/sshd 不挂：promote 语义是"图形交互登录链可用"
;; （桌面健康判据），tty/SSH 登录不证明图形链健康。optional：hook
;; 失败不阻塞会话（confirm 幂等，下次登录重试）。
(define (ephemeral-root-confirm-pam-service)
  (simple-service 'ephemeral-root-confirm-pam pam-root-service-type
                  (list (pam-extension
                         (transformer
                          (lambda (pam)
                            (if (string=? (pam-service-name pam) "greetd")
                                (pam-service
                                 (inherit pam)
                                 (session
                                  (append
                                   (pam-service-session pam)
                                   (list
                                    (pam-entry
                                     (control "optional")
                                     (module "pam_exec.so")
                                     (arguments
                                      (list
                                       (ephemeral-root-confirm-program))))))))
                                pam)))))))

(define* (one-shot-program-service name program documentation
                                   #:key (requirement '(user-processes)))
         "运行 PROGRAM 一次的 shepherd 服务。"
         (shepherd-service
          (provision (list name))
          (requirement requirement)
          (one-shot? #t)
          (documentation documentation)
          (start #~(lambda () (zero? (system* #$program))))
          (stop #~(const #f))))

(define (ephemeral-root-services keep)
  "无状态根的全部用户态服务。KEEP 是保留的旧 generation 数量。
confirm 经 PAM hook 挂在 greetd session（登录后）；cleanup 是
shepherd one-shot，锚定 persistent-state-ready（状态文件所在子卷
就绪即运行——远在 greetd 可见之前完成，与登录期 confirm 无状态
文件读写竞争；此前 confirm/cleanup 同在 user-processes 的先后序
约束随 confirm 移走而消失）。"
  (list (ephemeral-root-confirm-pam-service)
        (simple-service 'ephemeral-root-cleanup
                        shepherd-root-service-type
                        (list (one-shot-program-service
                               'ephemeral-root-cleanup
                               (ephemeral-root-cleanup-program keep)
                               "Delete old @root-N subvolumes beyond the \
configured retention."
                               #:requirement '(persistent-state-ready))))))
