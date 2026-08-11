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

(use-modules (guixcfg storage model)
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
  disk-install commit-root [target]    system init 后提交 root generation
                                       （@root-installing → @root-template + @root-0，
                                       target 默认 /mnt；之后即可 umount 并重启）

host 可选: vm, laptop~%"))

(define (load-policy host)
  "从纯存储模块加载 HOST policy；这里不能加载完整 host OS 模块。"
  (or (storage-policy-by-name host)
      (begin
       (format (current-error-port) "未知 host 或其存储 policy: ~a~%" host)
       (exit 1))))

(define (cmd-inspect device)
  (let ((facts (probe-device device)))
    (format #t "设备: ~a~%" (device-facts-path facts))
    (format #t "  by-id/path: ~a~%" (or (device-facts-by-id facts) "（无法解析）"))
    (format #t "  是分区:     ~a~%" (if (device-facts-partition? facts) "是" "否"))
    (format #t "  已挂载:     ~a~%" (if (device-facts-mounted? facts) "是" "否"))
    (format #t "  系统盘:     ~a~%" (if (device-facts-system-disk? facts) "是" "否"))
    (format #t "  LiveCD:     ~a~%" (if (device-facts-live-media? facts) "是" "否"))
    (format #t "  容量:       ~,2f GiB~%"
            (/ (device-facts-size facts) 1024.0 1024.0 1024.0))
    ;; inspect 不绑定具体 policy，容量下限检查用 VM 的下限做参考。
    (let ((failures (validate-target facts %vm-storage-policy)))
      (if (null? failures)
        (format #t "安全检查: 全部通过~%")
        (begin
         (format #t "安全检查: 未通过~%")
         (for-each (lambda (f)
                     (format #t "  - ~a~%" (check-failure-message f)))
                   failures))))))

(define (cmd-plan host device)
  (let ((policy (load-policy host)))
    (let ((failures (validate-policy policy)))
      (unless (null? failures)
        (format (current-error-port) "host policy 不合法，中止。~%")
        (exit 1)))
    (display-plan (storage-plan policy device))))

(define (cmd-apply host device)
  (run-install (load-policy host) device))

(define (cmd-commit-root target)
  (commit-root-generation target))

(define (main args)
  (match (cdr args)
         (("inspect" device)   (cmd-inspect device))
         (("plan" host device) (cmd-plan host device))
         (("apply" host device) (cmd-apply host device))
         (("commit-root")      (cmd-commit-root "/mnt"))
         (("commit-root" target) (cmd-commit-root target))
         (_ (usage) (exit 1))))

(main (command-line))
