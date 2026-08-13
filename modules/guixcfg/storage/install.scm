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
               #:export (run-install
                         read-secret-line
                         read-luks-passphrase!
                         make-luks-passphrase-source))

;;; ────────────────────────────────────────────────────────────
;;; LUKS passphrase 交互（docs/installation.md 第 30.3 节）。
;;;
;;; 目标：安装器只要求用户输入两次密码（设置 + 确认），同一
;;; passphrase 经 stdin 复用于 luksFormat（--batch-mode）与首次
;;; cryptsetup open。passphrase 仅存在于本次 apply session 的内存中：
;;; 不落盘、不进 /gnu/store、不进 argv/environment、不进 plan、
;;; 不写入 machine facts。Guile 字符串不做 cryptographic secure
;;; erasure 承诺——只避免明显泄漏路径。

(define (read-secret-line prompt)
  "关闭终端回显读取一行；读取后输出换行，让下一个提示从新行开始
（-echo 关闭了回车键的回显，不显式换行会与上一行黏在一起）。
stdin 非 tty（测试/管道）时直接读，不做终端控制。
stty 属于 GNU coreutils，由 installer manifest 显式提供
（manifests/installer.scm）。"
  (format #t "~a" prompt)
  (force-output)
  (let ((line (if (isatty? (current-input-port))
                (dynamic-wind
                 (lambda () (system "stty -echo"))
                 (lambda () (read-line))
                 (lambda () (system "stty echo")))
                (read-line))))
    (format #t "~%")
    line))

(define (read-luks-passphrase!)
  "交互设置 LUKS recovery password：两次输入一致且非空，否则重试。
TPM2 使用独立随机 credential/keyslot，本密码保留为人工 recovery
password（docs/boot.md 第 16.4 节）。"
  (let loop ()
    (let ((a (read-secret-line "设置 LUKS 密码: "))
          (b (read-secret-line "再次输入 LUKS 密码: ")))
      (cond
        ((not (string=? a b))
         (format #t "两次密码不一致，请重新输入。~%")
         (loop))
        ((string-null? a)
         (format #t "密码不能为空，请重新输入。~%")
         (loop))
        (else a)))))

(define (make-luks-passphrase-source reader)
  "返回一个 thunk：首次调用用 READER 读取 LUKS passphrase 并暂存，
之后返回同一值。passphrase 只存在于本次 apply session。"
  (let ((passphrase #f))
    (lambda ()
      (or passphrase
          (let ((p (reader)))
            (set! passphrase p)
            p)))))

;;; ────────────────────────────────────────────────────────────
;;; 步骤分派：把 plan 步骤 id 映射到执行函数。
;;; 每个执行函数接收步骤的 detail alist 与 apply session 的
;;; passphrase thunk（LUKS 相关步骤用）。

(define (detail-ref detail key)
  (or (assq-ref detail key)
      (error "计划步骤缺少参数" key)))

(define %executors
  `((confirm-target      . ,(lambda (d passphrase!) #t))    ; 人工确认在 execute-plan 前完成
                                                            (wipe                . ,(lambda (d passphrase!) (execute-wipe (detail-ref d 'device))))
                                                            (partition           . ,(lambda (d passphrase!) (execute-partition (detail-ref d 'device)
                                                                                                                               (detail-ref d 'esp-size))))
                                                            (wait-udev           . ,(lambda (d passphrase!) (execute-wait-udev (detail-ref d 'device))))
                                                            (format-esp          . ,(lambda (d passphrase!) (execute-format-esp)))
                                                            ;; LUKS passphrase 来自 apply session（luks-format 首次读取，
                                                            ;; luks-open 复用同一值），经 stdin 传给 cryptsetup。
                                                            (luks-format         . ,(lambda (d passphrase!)
                                                                                      (execute-luks-format (passphrase!))))
                                                            (luks-open           . ,(lambda (d passphrase!)
                                                                                      (catch #t
                                                                                        (lambda () (execute-luks-open (passphrase!)))
                                                                                        (lambda args
                                                                                          (format (current-error-port)
                                                                                                  "LUKS 卷已创建，但首次打开失败；不会重跑 luksFormat。~%")
                                                                                          (apply throw args)))))
                                                            (format-btrfs        . ,(lambda (d passphrase!) (execute-format-btrfs (detail-ref d 'device))))
                                                            (mount-top           . ,(lambda (d passphrase!) (execute-mount-top)))
                                                            (make-subvolume      . ,(lambda (d passphrase!) (execute-make-subvolume (detail-ref d 'name))))
                                                            (make-root-installing . ,(lambda (d passphrase!) (execute-make-root-installing (detail-ref d 'name))))
                                                            (make-swapfile       . ,(lambda (d passphrase!) (execute-make-swapfile (detail-ref d 'subvolume)
                                                                                                                                   (detail-ref d 'size))))
                                                            (unmount-top         . ,(lambda (d passphrase!) (execute-unmount-top)))
                                                            (mount-root          . ,(lambda (d passphrase!) (execute-mount-root (detail-ref d 'name)
                                                                                                                                (detail-ref d 'target))))
                                                            (mount-subvolume     . ,(lambda (d passphrase!) (execute-mount-subvolume (detail-ref d 'name)
                                                                                                                                     (detail-ref d 'target)
                                                                                                                                     (detail-ref d 'options))))
                                                            (mount-esp           . ,(lambda (d passphrase!) (execute-mount-esp (detail-ref d 'target))))
                                                            (write-facts         . ,(lambda (d passphrase!) (write-machine-facts (detail-ref d 'target))))
                                                            (ready               . ,(lambda (d passphrase!) #t))))

(define (execute-step step passphrase!)
  (let ((executor (assq-ref %executors (plan-step-id step))))
    (unless executor
      (error "未知的计划步骤" (plan-step-id step)))
    (executor (plan-step-detail step) passphrase!)))

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
  "逐步执行计划（失败即停）。
LUKS passphrase 由 luks-format 步骤首次读取，luks-open 复用同一值；
它只存在于本次 apply session（不进 plan、不落盘、不进 argv/env）。"
  (let ((passphrase! (make-luks-passphrase-source read-luks-passphrase!)))
    (catch #t
      (lambda ()
        (for-each
         (lambda (step n)
           (format #t "~%[~2d/~2d] ~a~%" n (length plan) (plan-step-summary step))
           (execute-step step passphrase!))
         plan
         (map (lambda (i) (+ i 1)) (iota (length plan))))
        (format #t "~%磁盘安装完成。~%"))
      (lambda (key . args)
        (format (current-error-port)
                "~%步骤失败，已立即停止（未完成的操作不会自动继续）。~%错误: ~s ~s~%"
                key args)
        (exit 1)))))

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
;;; 安装后提醒：LiveCD 的 /gnu/store 在内存盘（tmpfs）上。
;;; 若忘记 herd start cow-store /mnt 就直接 guix system init，
;;; 下载和构建会写满内存盘（docs/installation.md 第 30.2 节）。

(define (warn-if-store-in-ram)
  "若 /gnu/store 仍在 tmpfs 上，醒目提醒先 herd start cow-store /mnt。"
  (let ((fstype (first-command-line "findmnt" "-no" "FSTYPE" "/gnu/store")))
    (when (equal? fstype "tmpfs")
      (format #t "~%==================================================~%")
      (format #t "  注意: /gnu/store 目前在内存盘 (tmpfs) 上。~%")
      (format #t "  执行 guix system init 之前，请先运行:~%")
      (format #t "~%    herd start cow-store /mnt~%")
      (format #t "~%  否则下载和构建会写满内存盘。~%")
      (format #t "==================================================~%"))))

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
    (execute-plan plan)
    
    ;; 5. 若 store 还在内存盘，提醒先 cow-store 再 init
    (warn-if-store-in-ram)))
