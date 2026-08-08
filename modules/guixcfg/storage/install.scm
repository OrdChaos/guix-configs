;;; 安装编排：校验 → 打印计划 → 人工确认 → 逐步执行（失败即停）。
;;; 对应 docs/installation.md 第 30 章与 docs/storage.md 第 31 章。

(define-module (guixcfg storage install)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage plan)
               #:use-module (guixcfg storage validate)
               #:use-module (guixcfg storage device)
               #:use-module (guixcfg storage partition)
               #:use-module (guixcfg storage filesystem)
               #:use-module (guixcfg storage subvolume)
               #:use-module (guix build utils)  ; mkdir-p
               #:use-module (ice-9 format)
               #:use-module (ice-9 rdelim)
               #:use-module (srfi srfi-1)
               #:export (run-install))

;;; ────────────────────────────────────────────────────────────
;;; 步骤分派：把 plan 步骤 id 映射到执行函数。
;;; 每个执行函数接收步骤的 detail alist。

(define (detail-ref detail key)
  (or (assq-ref detail key)
      (error "计划步骤缺少参数" key)))

(define %executors
  `((confirm-target      . ,(lambda (d) #t))    ; 人工确认在 execute-plan 前完成
                                                (wipe                . ,(lambda (d) (execute-wipe (detail-ref d 'device))))
                                                (partition           . ,(lambda (d) (execute-partition (detail-ref d 'device)
                                                                                                       (detail-ref d 'esp-size))))
                                                (wait-udev           . ,(lambda (d) (execute-wait-udev (detail-ref d 'device))))
                                                (format-esp          . ,(lambda (d) (execute-format-esp)))
                                                (luks-format         . ,(lambda (d) (execute-luks-format)))
                                                (luks-open           . ,(lambda (d) (execute-luks-open)))
                                                (format-btrfs        . ,(lambda (d) (execute-format-btrfs (detail-ref d 'device))))
                                                (mount-top           . ,(lambda (d) (execute-mount-top)))
                                                (make-subvolume      . ,(lambda (d) (execute-make-subvolume (detail-ref d 'name))))
                                                (make-root-installing . ,(lambda (d) (execute-make-root-installing (detail-ref d 'name))))
                                                (make-swapfile       . ,(lambda (d) (execute-make-swapfile (detail-ref d 'subvolume)
                                                                                                           (detail-ref d 'size))))
                                                (unmount-top         . ,(lambda (d) (execute-unmount-top)))
                                                (mount-root          . ,(lambda (d) (execute-mount-root (detail-ref d 'name)
                                                                                                        (detail-ref d 'target))))
                                                (mount-subvolume     . ,(lambda (d) (execute-mount-subvolume (detail-ref d 'name)
                                                                                                             (detail-ref d 'target)
                                                                                                             (detail-ref d 'options))))
                                                (mount-esp           . ,(lambda (d) (execute-mount-esp (detail-ref d 'target))))
                                                (write-facts         . ,(lambda (d) (write-machine-facts (detail-ref d 'target))))
                                                (ready               . ,(lambda (d) #t))))

(define (execute-step step)
  (let ((executor (assq-ref %executors (plan-step-id step))))
    (unless executor
      (error "未知的计划步骤" (plan-step-id step)))
    (executor (plan-step-detail step))))

;;; ────────────────────────────────────────────────────────────
;;; 人工确认：必须输入完整设备路径（docs/storage.md 第 31 章）。

(define (confirm-device! device)
  (format #t "~%将对 ~a 执行【不可撤销的破坏性操作】。~%" device)
  (format #t "请输入完整设备路径 ~a 以确认: " device)
  (force-output)
  (let ((input (read-line)))
    (unless (equal? input device)
      (format #t "输入不匹配，已中止，未做任何修改。~%")
      (exit 1))))

;;; ────────────────────────────────────────────────────────────
;;; 失败即停（docs/storage.md 第 31 章）：
;;; 任何一步抛异常，立即报告并退出非零，不做任何自动清理或续跑。

(define (execute-plan plan)
  (catch #t
    (lambda ()
      (for-each
       (lambda (step n)
         (format #t "~%[~2d/~2d] ~a~%" n (length plan) (plan-step-summary step))
         (execute-step step))
       plan
       (map (lambda (i) (+ i 1)) (iota (length plan))))
      (format #t "~%磁盘安装完成。~%"))
    (lambda (key . args)
      (format (current-error-port)
              "~%步骤失败，已立即停止（未完成的操作不会自动继续）。~%错误: ~s ~s~%"
              key args)
      (exit 1))))

;;; ────────────────────────────────────────────────────────────
;;; 执行前环境检查：在任何破坏性操作之前拦下环境问题
;;; （root 权限、所需命令齐全、mapper 名未被占用、设备非只读）。

(define %required-commands
  '("sgdisk" "udevadm" "mkfs.vfat" "cryptsetup" "mkfs.btrfs"
             "btrfs" "mount" "umount" "mkdir" "lsblk" "findmnt" "readlink"))

(define (preflight-environment! device)
  "检查安装环境本身；任何问题直接报错退出。"
  (unless (zero? (getuid))
    (error "apply 需要 root 权限"))
  
  (for-each
   (lambda (cmd)
     (unless (search-path (string-split (or (getenv "PATH") "") #\:) cmd)
       (error "所需命令不可用（检查 manifest 是否进入 installer 环境）" cmd)))
   %required-commands)
  
  (when (file-exists? (string-append "/dev/mapper/" %luks-mapper-name))
    (error "LUKS mapper 名已被占用（可能有上次未完成或正在使用的安装）"
           %luks-mapper-name))
  
  (let ((ro (first-command-line "lsblk" "-dno" "RO" device)))
    (when (equal? ro "1")
      (error "目标设备是只读的" device)))
  
  (format #t "环境检查通过（root、命令齐全、mapper 空闲、设备可写）。~%"))

;;; ────────────────────────────────────────────────────────────
;;; 机器事实（docs/storage.md 第 19 章）：安装时生成、可重新探测、不进 Git。
;;; initrd 里没有 udev，mapped-device 的 source 只能用 LUKS UUID
;;; （initrd 会扫描块设备匹配，无需 /dev/disk/by-* 符号链接）。

(define (write-machine-facts target)
  "把安装时发现的机器事实写入 TARGET/persist/system/facts/host.scm。"
  (let ((luks-uuid (first-command-line "cryptsetup" "luksUUID"
                                       (by-partlabel-path %system-partlabel))))
    (unless luks-uuid
      (error "无法读取 LUKS UUID" %system-partlabel))
    (let ((facts `((luks-uuid . ,luks-uuid)))
          (dir (string-append target "/persist/system/facts")))
      (mkdir-p dir)
      (call-with-output-file (string-append dir "/host.scm")
        (lambda (port)
          (write facts port)
          (newline port)))
      (format #t "  机器事实: ~s~%" facts))))

;;; ────────────────────────────────────────────────────────────
;;; 完整安装流程。

(define (run-install policy device)
  "把 DEVICE 安装成 POLICY 描述的布局。调用前需 root 权限。"
  ;; 0. 环境检查
  (preflight-environment! device)
  
  ;; 1. policy 自校验
  (let ((policy-failures (validate-policy policy)))
    (unless (null? policy-failures)
      (format (current-error-port) "host policy 不合法:~%")
      (for-each (lambda (f)
                  (format (current-error-port) "  - ~a~%" (check-failure-message f)))
                policy-failures)
      (exit 1)))
  
  ;; 2. 探测并校验目标设备
  (format #t "正在探测 ~a ...~%" device)
  (let ((failures (validate-target (probe-device device) policy)))
    (unless (null? failures)
      (format (current-error-port) "目标设备未通过安全检查:~%")
      (for-each (lambda (f)
                  (format (current-error-port) "  - ~a~%" (check-failure-message f)))
                failures)
      (exit 1)))
  
  ;; 3. 打印完整计划，人工确认
  (let ((plan (storage-plan policy device)))
    (display-plan plan)
    (confirm-device! device)
    
    ;; 4. 逐步执行
    (execute-plan plan)))
