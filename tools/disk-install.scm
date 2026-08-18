;;; 磁盘安装 CLI。
;;;
;;; 用法（从仓库根目录，apply 需要 root）：
;;;   guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- inspect /dev/vda
;;;   guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- plan vm /dev/vda
;;;   guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- apply vm /dev/vda
;;;
;;; inspect 和 plan 是只读操作；apply 是破坏性操作，校验和确认见
;;; docs/architecture/storage.md。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path（从仓库根目录运行）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guix build utils)           ; mkdir-p、copy-file、chmod
             (guixcfg security credential-source) ; resolve-luks-passphrase-source
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
  (format #t "Usage:
  disk-install inspect <device>        probe the device and print facts and safety checks (read-only)
  disk-install plan <host> <device>    print the install plan (read-only, nothing executed)
  disk-install apply <host> <device>   run the install (destructive, needs root and confirmation)
  disk-install apply <host> <device> --luks-secret
                                       LUKS passphrase read from an age secret
                                       (run 'secrets unlock' first)
  disk-install commit-root [target]    commit the root generation after 'system init'
                                       (@root-installing -> @root-template + @root-0,
                                       target defaults to /mnt; then umount and reboot)

host: vm, laptop~%"))

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
stable S，安装过程复用 /run 中的临时 S）；否则交互读取。来源解析
统一走 credential-source（与 tpm2-enroll 共享同一 resolver）。"
  (let ((reader (resolve-luks-passphrase-source
                 (if use-luks-secret? 'luks-secret 'interactive))))
    (run-install (load-policy host) device
                 #:passphrase-reader reader)))

(define* (ensure-installed-identity! target #:optional (runtime "/run/guixcfg-age/stable-identity"))
  "安装收尾（阶段 6 兜底）：/persist/system/keys/age/identity 必须就位——
首次 boot 的 secrets-deploy 用它解密（boot 后无 runtime identity），缺失
会导致 interactive-secrets-ready 失败、login barrier 卡死。缺失时从
RUNTIME（同一安装会话 unlock 的 identity）自动安装；无 runtime identity
则 fail fast（提示先 secrets unlock）。"
  (let ((installed (string-append target "/persist/system/keys/age/identity")))
    (unless (file-exists? installed)
      (if (file-exists? runtime)
        (begin
          (mkdir-p (dirname installed))
          (chmod (dirname installed) #o700)
          (copy-file runtime installed)
          (chmod installed #o600)
          (format #t "installed stable identity to ~a (stage 6 fallback)~%"
                  installed))
        (error "installed identity missing and no runtime identity; run 'secrets unlock' first (installation stage 6)")))))

(define (cmd-commit-root target)
  (ensure-installed-identity! target)
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
