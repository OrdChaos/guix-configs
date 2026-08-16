;;; 磁盘安装 CLI。
;;;
;;; 用法（从仓库根目录，apply 需要 root）：
;;;   guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- inspect /dev/vda
;;;   guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- plan vm /dev/vda
;;;   guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- apply vm /dev/vda
;;;
;;; inspect 和 plan 是只读操作；apply 是破坏性操作，校验和确认见
;;; docs/storage.md 第 31 章。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path（从仓库根目录运行）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg security age)      ; runtime-identity-present?、make-age-secret-reader
             (guixcfg storage model)
             (guixcfg storage policies)
             (guixcfg storage plan)
             (guixcfg storage validate)
             (guixcfg storage device)
             (guixcfg storage install)
             (guixcfg storage commit)
             (ice-9 format)
             (ice-9 match))

(define (usage)
  (format #t "用法:
  disk-install inspect <device>        探测设备并打印事实与安全检查结果（只读）
  disk-install plan <host> <device>    打印安装计划（只读，不执行）
  disk-install apply <host> <device>   执行安装（破坏性，需要 root 和人工确认）
  disk-install apply <host> <device> --luks-secret
                                       LUKS passphrase 从 age secret 读取
                                       （需先 secrets unlock）
  disk-install commit-root [target]    system init 后提交 root generation
                                       （@root-installing → @root-template + @root-0，
                                       target 默认 /mnt；之后即可 umount 并重启）

host 可选: vm, laptop~%"))

(define (load-policy host)
  "从纯存储模块加载 HOST policy；这里不能加载完整 host OS 模块。"
  (or (storage-policy-by-name host)
      (begin
       (format (current-error-port) "unknown host or its storage policy: ~a~%" host)
       (exit 1))))

(define (cmd-inspect device)
  (let ((facts (probe-device device)))
    (format #t "device: ~a~%" (device-facts-path facts))
    (format #t "  by-id/path: ~a~%" (or (device-facts-by-id facts) (unresolved)))
    (format #t "  is a partition: ~a~%" (if (device-facts-partition? facts) "yes" "no"))
    (format #t "  mounted:     ~a~%" (if (device-facts-mounted? facts) "yes" "no"))
    (format #t "  system disk: ~a~%" (if (device-facts-system-disk? facts) "yes" "no"))
    (format #t "  LiveCD:     ~a~%" (if (device-facts-live-media? facts) "yes" "no"))
    (format #t "  size:        ~,2f GiB~%"
            (/ (device-facts-size facts) 1024.0 1024.0 1024.0))
    ;; inspect 不绑定具体 policy，容量下限检查用 VM 的下限做参考。
    (let ((failures (validate-target facts %vm-storage-policy)))
      (if (null? failures)
        (format #t "safety checks: all passed~%")
        (begin
         (format #t "safety checks: failed~%")
         (for-each (lambda (f)
                     (format #t "  - ~a~%" (check-failure-message f)))
                   failures))))))

(define (cmd-plan host device)
  (let ((policy (load-policy host)))
    (let ((failures (validate-policy policy)))
      (unless (null? failures)
        (format (current-error-port) "host policy is invalid; aborting.~%")
        (exit 1)))
    (display-plan (storage-plan policy device))))

(define (cmd-apply host device use-luks-secret?)
  "USE-LUKS-SECRET? 时 LUKS passphrase 来自 secrets/install/
luks-recovery.age（需先 secrets unlock；master password 只解锁一次
stable S，安装过程复用 /run 中的临时 S）；否则交互读取。"
  (if use-luks-secret?
      (unless (runtime-identity-present?)
        (format (current-error-port)
                "no unlocked stable identity; run 'secrets unlock' first~%")
        (exit 1))
      #t)
  (let ((reader (if use-luks-secret?
                    (make-age-secret-reader
                     "secrets/install/luks-recovery.age")
                    read-luks-passphrase!)))
    (run-install (load-policy host) device
                 #:passphrase-reader reader)))

(define (cmd-commit-root target)
  (commit-root-generation target))

(define (main args)
  (match (cdr args)
         (("inspect" device)   (cmd-inspect device))
         (("plan" host device) (cmd-plan host device))
         (("apply" host device) (cmd-apply host device #f))
         (("apply" host device "--luks-secret")
          (cmd-apply host device #t))
         (("commit-root")      (cmd-commit-root "/mnt"))
         (("commit-root" target) (cmd-commit-root target))
         (_ (usage) (exit 1))))

(main (command-line))
