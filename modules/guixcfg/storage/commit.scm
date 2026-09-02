;;; 安装期提交：system init 完成后，把 @root-installing 固化为
;;; 只读 @root-template + 可写 @root-0，并写入初始 root generation 状态。
;;; 对应 docs/architecture/storage.md。
;;;
;;; 时机：disk-install apply → herd start cow-store /mnt → guix system init
;;; 之后、umount /mnt 之前执行（此时 /mnt 仍挂着 @root-installing）。
;;;
;;; /var/guix 的特殊处理：init 期间 @persist-var-guix 刻意不挂载
;;; （见 model.scm 的 mount-at-install? 注释）——guix system init 会
;;; delete-file-recursively 目标的 /var/guix 重新开始，挂载点删不掉
;;; （EBUSY）会让 profile 注册不可靠。因此 init 让 /var/guix 以普通
;;; 目录建在 @root-installing 里（对 init 来说完全是原生环境），
;;; 提交时再把内容收进 @persist-var-guix 子卷。
;;;
;;; 提交模型（决定性实验验证，见 tests/test-commit-root.scm）：
;;;   @root-installing 本身就是 generation 0——commit 的语义是
;;;   「正式命名为 @root-0」（rename），而不是复制后删除当前挂载源。
;;;   Btrfs 下 rename 已挂载的 subvolume：挂载保持、内容保持可见、
;;;   subvolume id 不变，只是顶层路径名改变。删除已挂载的 source
;;;   会让 TARGET 视图失效（实测 bug），因此绝不再 delete。

(define-module (guixcfg storage commit)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage root-generation)
               #:use-module (guixcfg storage subvolume)
               #:use-module (guixcfg storage device)
               #:use-module (guixcfg boot layout)  ; ESP/部署脚本路径固定事实
               #:use-module (guix build utils)  ; mkdir-p、delete-file-recursively
               #:use-module (srfi srfi-13)  ; string-contains
               #:use-module (ice-9 format)
               #:export (commit-state
                         commit-root-generation))

(define (top-path name)
  (string-append %btrfs-top-mount "/" name))

(define (template-new-name)
  (string-append %root-template-name ".new"))

(define (state-path)
  (state-file-path (top-path "@persist-system")))

;;; ────────────────────────────────────────────────────────────
;;; 幂等判定：安装提交的 committed predicate。
;;; 综合 @root-0 / @root-installing / state 三要素，不靠单一文件猜。

(define (commit-state)
  "返回安装提交状态符号：
  committed                —— @root-0 与 state 均存在（已提交，no-op）
  interrupted-after-rename —— @root-0 存在但 state 缺失（上次 rename 后中断，可恢复）
  not-committed            —— @root-installing 存在（正常提交路径）
  unknown                  —— 两者皆无（异常，人工检查）"
  (let ((root0 (top-path (root-generation-name 0)))
        (installing (top-path %root-installing-name)))
    (cond
      ((and (file-exists? root0) (file-exists? (state-path))) 'committed)
      ((file-exists? root0) 'interrupted-after-rename)
      ((file-exists? installing) 'not-committed)
      (else 'unknown))))

;;; ────────────────────────────────────────────────────────────
;;; 前置检查：确认处于“init 已完成、尚未提交”的中间态。

(define (preflight-commit! target)
  "TARGET 是安装目标挂载点（通常 /mnt）。"
  (unless (zero? (getuid))
    (error "commit-root requires root privileges"))
  
  ;; TARGET 必须挂着 btrfs subvolume（@root-installing 或中断恢复时的
  ;; @root-0——具体由 commit-state 分支校验）。
  (let ((source (first-command-line "findmnt" "-no" "SOURCE" target)))
    (unless (and source (string-contains source "[/@"))
      (error "target is not mounted from a btrfs subvolume; cannot commit"
             target source)))
  
  ;; system init 应已完成：/etc 已由 init 生成。
  (unless (file-exists? (string-append target "/etc"))
    (error "target has no /etc; guix system init has not been run" target)))

;;; ────────────────────────────────────────────────────────────
;;; /var/guix 收养：把 init 写好的注册信息从 @root-installing 搬进
;;; @persist-var-guix，模板里留空目录作运行时挂载点。
;;; 幂等：已收养（dst/db 存在）时只确保 src 是空挂载点目录。

(define (adopt-var-guix!)
  "移动 /var/guix 内容到 @persist-var-guix。调用时 Btrfs 顶层已挂载。"
  (let ((src (string-append (top-path %root-installing-name) "/var/guix"))
        (dst (top-path "@persist-var-guix")))
    (if (file-exists? (string-append dst "/db"))
      (begin
       ;; 上次中断已收养：确保 src 仍是空挂载点目录（不重复 cp）
       (unless (file-exists? src) (mkdir-p src))
       (format #t "(/var/guix already adopted; skipping)~%"))
      (begin
       (unless (file-exists? (string-append src "/db"))
         (error "init did not create /var/guix/db; adoption aborted" src))
       ;; 跨子卷不能 rename，复制后删除（内容只有 db 和少量链接，很小）。
       (invoke "cp" "-a" (string-append src "/.") (string-append dst "/"))
       (delete-file-recursively src)
       (mkdir-p src)          ; 留空目录作运行时挂载点
       (format #t "/var/guix adopted into @persist-var-guix~%")))))

;;; ────────────────────────────────────────────────────────────
;;; template publish：只读候选快照 → 原子改名发布。
;;; 已存在的旧 template 是上次中断的候选（内容来自同一 source），
;;; 删除重做；template 永远 readonly（发布后校验 ro=true）。

(define (publish-template! source-name)
  "从 SOURCE-NAME（@root-installing 或中断恢复时的 @root-0）生成
只读 @root-template。失败时 SOURCE 不动、TARGET 仍可用。"
  (let ((source (top-path source-name)))
    (when (file-exists? (top-path %root-template-name))
      (invoke "btrfs" "subvolume" "delete" (top-path %root-template-name)))
    (false-if-exception (delete-file (top-path (template-new-name))))
    (invoke "btrfs" "subvolume" "snapshot" "-r"
            source (top-path (template-new-name)))
    (unless (file-exists? (top-path (template-new-name)))
      (error "template snapshot verification failed; aborting commit"))
    (rename-file (top-path (template-new-name)) (top-path %root-template-name))
    ;; template 永远 readonly（决定性不变式）
    (let ((ro (first-command-line "btrfs" "property" "get"
                                  (top-path %root-template-name) "ro")))
      (unless (and ro (string-contains ro "ro=true"))
        (error "template is not read-only; aborting" ro)))
    (format #t "published read-only template ~a~%" %root-template-name)))

;;; ────────────────────────────────────────────────────────────
;;; generation 0：rename（而非 snapshot + delete——删除已挂载 source
;;; 会让 TARGET 视图失效，实测 bug）。Btrfs rename 保持挂载与 subvolume
;;; id（决定性实验），TARGET 在 commit 后仍是完整可访问的已安装 root。

(define (commit-generation-zero!)
  (rename-file (top-path %root-installing-name)
               (top-path (root-generation-name 0)))
  (format #t "committed ~a (renamed from ~a; mount view preserved)~%"
          (root-generation-name 0) %root-installing-name))

;;; ────────────────────────────────────────────────────────────
;;; TARGET 不变式检查（rename 后立即做；失败即回滚，不写 state 不 deploy）。

(define (verify-target! target)
  (for-each
   (lambda (d)
     (unless (file-exists? (string-append target "/" d))
       (error "TARGET missing directory after commit; aborting (state not written, no deploy)" d target)))
   '("etc" "gnu" "persist" "boot"))
  (format #t "TARGET integrity checks passed (etc/gnu/persist/boot)~%"))

;;; ────────────────────────────────────────────────────────────
;;; UKI 部署：rename 后 TARGET/boot/deploy-uki 必须可见（挂载视图
;;; 保持的实证）。缺失时区分 expected（非 UKI bootloader，GRUB host）
;;; 与 unexpected（ESP 已有 limine.conf 的 UKI 痕迹却缺脚本）。

(define (deploy-uki! target)
  (let ((deploy (string-append target %uki-deploy-script-path)))
    (cond
      ((file-exists? deploy)
       (invoke deploy target %esp-mount-point)   ; ESP 固定挂载点（boot/layout）
       (format #t "deploy-uki executed (~a)~%" deploy))
      ((file-exists? (string-append target %esp-mount-point "/limine.conf"))
       (error "UKI bootloader deployed (ESP has limine.conf) but deploy-uki script is missing"
              deploy))
      (else
       (format #t "(no deploy-uki: non-UKI bootloader is expected; skipping deploy refresh; \
check manually on non-GRUB hosts)~%")))))

;;; ────────────────────────────────────────────────────────────
;;; 初始状态写入（commit record，最后写——deploy 成功后才宣布提交）。

(define (write-initial-state!)
  (let* ((persist-system (top-path "@persist-system"))
         (dir (string-append persist-system "/" %root-generations-dir-name))
         (state (initial-state (current-time))))
    (mkdir-p dir)
    (write-state! (state-file-path persist-system) state)
    (format #t "initial state: ~s~%" (state->alist state))))

;;; ────────────────────────────────────────────────────────────
;;; 失败恢复：rename 已发生时回滚（Btrfs rename 可逆——决定性实验），
;;; 删除中断残留（.new 快照与已发布的 template），恢复 pre-commit 状态。
;;; adopt-var-guix 已完成的收养保持（幂等，重跑不重复复制）。

(define (rollback-commit!)
  "尽力回滚：@root-0 → @root-installing + 清理 template/.new。"
  (let ((root0 (top-path (root-generation-name 0)))
        (installing (top-path %root-installing-name)))
    (when (and (file-exists? root0) (not (file-exists? installing)))
      (false-if-exception
       (rename-file root0 installing))
      (format #t "rolled back: ~a -> ~a~%" (root-generation-name 0)
              %root-installing-name)))
  (false-if-exception
   (invoke "btrfs" "subvolume" "delete" (top-path %root-template-name)))
  (false-if-exception
   (invoke "btrfs" "subvolume" "delete" (top-path (template-new-name)))))

;;; ────────────────────────────────────────────────────────────
;;; 提交本体（docs/architecture/storage.md）：
;;; 收养 /var/guix → 发布只读模板 → rename @root-0 → 验证 TARGET →
;;; deploy UKI → 最后写初始状态。state 是 commit record：关键步骤
;;; 未成功时不宣布 generation 0 committed。

(define (commit-root-generation target)
  "把 TARGET（通常 /mnt）上的安装期 root 固化为 template + @root-0。
幂等：已提交（committed）时安全 no-op；rename 后中断可自动恢复。"
  (preflight-commit! target)
  (execute-mount-top)
  (catch #t
    (lambda ()
      (case (commit-state)
        ((committed)
         (format #t "installation already committed (@root-0 and state present); no-op~%")
         (execute-unmount-top)
         'committed)
        ((unknown)
         (error "unexpected state: neither @root-installing nor @root-0 exists; inspect top level manually"))
        (else
         (if (eq? (commit-state) 'interrupted-after-rename)
           (begin
            ;; 上次在 rename 后、state 前中断：恢复完成剩余步骤。
            ;; 此时 TARGET 挂着 @root-0（挂载跟随 rename）。
            (format #t "previous commit was interrupted after rename; resuming remaining steps~%")
            (unless (file-exists? (top-path %root-template-name))
              (publish-template! (root-generation-name 0))))
           (begin
            ;; 正常路径：确认 TARGET 挂的是 @root-installing
            (let ((source (first-command-line "findmnt" "-no" "SOURCE" target)))
              (unless (and source (string-contains source %root-installing-name))
                (error "target is not mounted from the installing root (@root-installing)" target source)))
            ;; 1. 收养 /var/guix（必须在快照之前：模板应含空的 /var/guix
            ;;    挂载点，而子卷应含 init 写入的注册内容）
            (adopt-var-guix!)
            ;; 2. 发布只读模板（失败时 source 不动）
            (publish-template! %root-installing-name)
            ;; 3. rename 安装期 root 为 generation 0（不再 snapshot+delete）
            (commit-generation-zero!)))
         ;; 4. 验证 TARGET 仍完整（rename 后不变式）
         (verify-target! target)
         ;; 5. deploy UKI（rename 后 TARGET 视图保持，deploy 可执行）
         (deploy-uki! target)
         ;; 6. state 最后写（commit record）
         (write-initial-state!)
         (execute-unmount-top)
         (format #t "~%Install-time commit complete. You may umount -R ~a and reboot; \
first boot will use @root-0 (state first-boot).~%" target)
         'committed)))
    (lambda (key . args)
      ;; 失败：回滚（rename 已发生则还原）并清理残留，然后报告。
      (catch #t
        (lambda () (rollback-commit!))
        (lambda _ #t))
      (catch #t
        (lambda () (execute-unmount-top))
        (lambda _ #t))
      (format (current-error-port)
              "~%commit failed; rolled back to a rerunnable state (@root-installing remains).~%error: ~s ~s~%"
              key args)
      (exit 1))))
