;;; 安装期提交：system init 完成后，把 @root-installing 固化为
;;; 只读 @root-template + 可写 @root-0，并写入初始 root generation 状态。
;;; 对应 docs/storage.md 第 17.3 节。
;;;
;;; 时机：disk-install apply → herd start cow-store /mnt → guix system init
;;; 之后、umount /mnt 之前执行（此时 /mnt 仍挂着 @root-installing）。

(define-module (guixcfg storage commit)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage root-generation)
               #:use-module (guixcfg storage subvolume)
               #:use-module (guixcfg storage device)
               #:use-module (guix build utils)  ; mkdir-p
               #:use-module (srfi srfi-13)  ; string-contains
               #:use-module (ice-9 format)
               #:export (commit-root-generation))

(define (top-path name)
  (string-append %btrfs-top-mount "/" name))

(define (template-new-name)
  (string-append %root-template-name ".new"))

(define (root-zero-new-name)
  (string-append (root-generation-name 0) ".new"))

;;; ────────────────────────────────────────────────────────────
;;; 前置检查：确认处于“init 已完成、尚未提交”的中间态。

(define (preflight-commit! target)
  "TARGET 是安装目标挂载点（通常 /mnt）。"
  (unless (zero? (getuid))
    (error "commit-root 需要 root 权限"))
  
  ;; TARGET 必须挂着 @root-installing（btrfs 的 findmnt SOURCE 形如
  ;; /dev/mapper/cryptroot[/@root-installing]）。
  (let ((source (first-command-line "findmnt" "-no" "SOURCE" target)))
    (unless (and source (string-contains source %root-installing-name))
      (error "目标挂载的不是安装期 root（@root-installing），无法提交"
             target source)))
  
  ;; system init 应已完成：/etc 已由 init 生成。
  (unless (file-exists? (string-append target "/etc"))
    (error "目标上没有 /etc，疑似尚未执行 guix system init" target))
  
  ;; 尚未提交过。
  (when (file-exists? (state-file-path (string-append target "/persist/system")))
    (error "root generation 状态已存在，本次安装已提交过"
           (state-file-path (string-append target "/persist/system")))))

;;; ────────────────────────────────────────────────────────────
;;; 提交本体（docs/storage.md 第 17.3 节）：
;;; 先建 .new 快照，验证成功后事务性改名，最后删除 @root-installing。

(define (commit-root-generation target)
  "把 TARGET（通常 /mnt）上的安装期 root 固化为 template + @root-0。"
  (preflight-commit! target)
  (execute-mount-top)
  (catch #t
    (lambda ()
      ;; 顶层现状检查
      (unless (file-exists? (top-path %root-installing-name))
        (error "顶层缺少 @root-installing" (top-path %root-installing-name)))
      (for-each
       (lambda (name)
         (when (file-exists? (top-path name))
           (error "顶层已存在最终 generation，疑似重复提交" name)))
       (list %root-template-name (root-generation-name 0)))
      
      ;; 1. 创建 .new 快照：template 只读，@root-0 可写
      (format #t "创建只读模板快照 ~a.new~%" %root-template-name)
      (invoke "btrfs" "subvolume" "snapshot" "-r"
              (top-path %root-installing-name) (top-path (template-new-name)))
      (format #t "创建可写 generation 快照 ~a~%" (root-zero-new-name))
      (invoke "btrfs" "subvolume" "snapshot"
              (top-path %root-installing-name) (top-path (root-zero-new-name)))
      
      ;; 2. 验证后事务性提交（改名是单目录项操作）
      (unless (and (file-exists? (top-path (template-new-name)))
                   (file-exists? (top-path (root-zero-new-name))))
        (error "快照验证失败，中止提交"))
      (rename-file (top-path (template-new-name)) (top-path %root-template-name))
      (rename-file (top-path (root-zero-new-name))
                   (top-path (root-generation-name 0)))
      (format #t "已提交 ~a 与 ~a~%"
              %root-template-name (root-generation-name 0))
      
      ;; 3. 删除安装期 root（仍挂在 TARGET 上没关系，卸载后自动释放）
      (invoke "btrfs" "subvolume" "delete" (top-path %root-installing-name))
      (format #t "已删除 ~a~%" %root-installing-name)
      
      ;; 4. 写入初始状态（第 17.7 节）：@root-0 就绪但从未启动
      (let* ((persist-system (top-path "@persist-system"))
             (dir (string-append persist-system "/" %root-generations-dir-name))
             (state (initial-state (current-time))))
        (mkdir-p dir)
        (call-with-output-file (state-file-path persist-system)
                               (lambda (port)
                                 (write (state->alist state) port)
                                 (newline port)))
        (format #t "初始状态: ~s~%" (state->alist state)))
      
      (execute-unmount-top)
      (format #t "~%安装期提交完成。可以 umount -R ~a 并重启，
首次启动将使用 @root-0（状态 first-boot）。~%" target))
    (lambda (key . args)
      ;; 尽量卸载顶层，再报告失败（不做任何自动回滚）
      (catch #t
        (lambda () (execute-unmount-top))
        (lambda _ #t))
      (format (current-error-port)
              "~%提交失败，已停止（中间态的 .new 快照请人工检查）。~%错误: ~s ~s~%"
              key args)
      (exit 1))))
