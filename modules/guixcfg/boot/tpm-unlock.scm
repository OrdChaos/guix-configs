;;; initrd 内 TPM 自动解锁尝试（运行时模块）。
;;; （独立模块：不能被 (guixcfg boot initrd) 的模块闭包循环依赖。
;;;  PCR7-aware mapped-device-kind 定义在 (guixcfg system file-systems)
;;;  ——config 侧模块，可自由 import (guix gexp)/(gnu packages …)。
;;;  本模块必须保持【运行时纯净】：只能 import guile core / guix build /
;;;  guixcfg 纯模块。initrd 闭包若引入 (guix gexp)/(guix utils)（其
;;;  version-compare 在模块加载时 dlsym strverscmp），guile-static-initrd
;;;  静态链接无法解析符号，module-import-compiled 构建失败——实测。）
;;;
;;; 语义（docs/boot.md 第 16.4 节，PCR7-only）：
;;;   - cmdline 门控（rootmode=recovery / guixcfg.tpm-unlock=0 → 跳过）
;;;   - PARTLABEL 设备发现（initrd 无 udev：/sys/block 扫描）
;;;   - 挂 ESP → 读机器级 artifact（/EFI/Guix/tpm2/，不随 UKI slot 变化）
;;;   - PolicyPCR(实际 PCR7) → unseal stdout 管道 → cryptsetup open
;;;     --key-file=-
;;;   - 任意失败 → 返回 #f → kind 回退标准交互密码（永不 emergency
;;;     shell）

(define-module (guixcfg boot tpm-unlock)
               #:use-module (guixcfg storage model)        ; %luks-mapper-name
               #:use-module (guixcfg security tpm2 tpm2-tools)
               #:use-module (guix build utils)             ; mkdir-p
               #:use-module (guix build syscalls)          ; mount、umount、mknod
               #:use-module (ice-9 ftw)                    ; scandir
               #:use-module (ice-9 regex)                  ; string-match
               #:use-module (ice-9 rdelim)                 ; read-line
               #:use-module (ice-9 binary-ports)           ; get-bytevector-all/n
               #:use-module (ice-9 popen)                  ; open-pipe*
               #:use-module (rnrs bytevectors)             ; utf8->string
               #:use-module (rnrs io ports)                ; put-bytevector
               #:use-module (srfi srfi-1)                  ; first
               #:use-module (srfi srfi-13)                 ; string-tokenize
               #:export (tpm-unlock-in-initrd
                         ensure-partlabel-links!
                         partname-device
                         cmdline-option
                         proc-cmdline-option
                         tpm-unlock-candidate?))

;; initrd 里 ESP 的临时挂载点与机器级 artifact 目录（PCR7 不随
;; UKI slot 变化，固定路径；enrollment 工具写，见 tools/tpm2-enroll.scm）。
(define %esp-tpm-mount "/run/guixcfg-esp")
(define %esp-tpm2-dir "EFI/Guix/tpm2")

;;; ────────────────────────────────────────────────────────────
;;; cmdline 解析（纯函数便于测试）

(define (cmdline-option line name)
  "从 CMDLINE 字符串读 NAME=VALUE 选项的值；不存在返回 #f。"
  (and line
       (let loop ((args (string-tokenize line)))
         (cond
           ((null? args) #f)
           ((string-prefix? (string-append name "=") (car args))
            (string-drop (car args) (+ 1 (string-length name))))
           (else (loop (cdr args)))))))

(define (proc-cmdline-option name)
  "从 /proc/cmdline 读 NAME=VALUE 选项的值；不存在返回 #f。"
  (cmdline-option (false-if-exception
                   (call-with-input-file "/proc/cmdline"
                                         (lambda (p) (read-line p))))
                  name))

;;; ────────────────────────────────────────────────────────────
;;; 设备发现（initrd 无 udev；实测 workaround，来自旧 TPM era）

(define (partname-device label)
  "遍历 /sys/block/*/*/uevent 找 PARTNAME=LABEL 的分区，返回
/dev/<分区名>；找不到返回 #f。不依赖 udev/blkid。"
  (let loop ((devices (or (scandir "/sys/block") '())))
    (if (null? devices)
      #f
      (let* ((dev (car devices))
             (dev-dir (string-append "/sys/block/" dev)))
        (if (or (string-prefix? "." dev)
                (not (eq? 'directory (stat:type (stat dev-dir)))))
          (loop (cdr devices))
          (let loop2 ((parts (or (scandir dev-dir) '())))
            (if (null? parts)
              (loop (cdr devices))
              (let* ((part (car parts))
                     (part-dir (string-append dev-dir "/" part))
                     (uevent (string-append part-dir "/uevent")))
                (if (and (not (string-prefix? "." part))
                         (file-exists? uevent)
                         (let ((content (call-with-input-file uevent
                                                              (lambda (p)
                                                                (get-string-all p)))))
                           (let ((m (string-match "PARTNAME=([^\n]+)" content)))
                             (and m (string=? (match:substring m 1) label)))))
                  (string-append "/dev/" part)
                  (loop2 (cdr parts)))))))))))

(define (ensure-partlabel-links!)
  "initrd 无 udev：创建分区设备节点与 /dev/disk/by-partlabel/ 链接
（块设备主次号来自 /sys/block/<dev>/dev，mknod 用
(guix build syscalls) 的符号类型 'block）。"
  (let ((dir "/dev/disk/by-partlabel"))
    (mkdir-p dir)
    (for-each
     (lambda (label)
       (let ((dev (partname-device label)))
         (when dev
           (let ((name (basename dev)))
             ;; mknod 块设备（主:次 从 sysfs）
             (let* ((sys (string-append "/sys/block/" name "/dev")))
               (when (file-exists? sys)
                 (let* ((nums (call-with-input-file sys
                                                    (lambda (p) (read-line p))))
                        (maj (string-take nums (string-index nums #\:)))
                        (min (string-drop nums (+ 1 (string-index nums #\:)))))
                   (false-if-exception
                    (mknod dev 'block
                           (+ (* (string->number maj) 256)
                              (string->number min)))))))
             (false-if-exception
              (symlink dev (string-append dir "/" label)))))))
     '("esp" "system"))))

;;; ────────────────────────────────────────────────────────────
;;; 决策纯函数（测试用）

(define (tpm-unlock-candidate? recovery? tpm-available? artifacts-present?)
  "是否应尝试 TPM 自动解锁：非 Recovery 且 TPM 可用且 artifact 完整。"
  (and (not recovery?)
       tpm-available?
       artifacts-present?))

;;; ────────────────────────────────────────────────────────────
;;; initrd 解锁尝试

(define (tpm-unlock-in-initrd tpm2-bin cryptsetup-bin)
  "initrd 内的 TPM 自动解锁尝试。返回 #t 表示 LUKS（cryptroot）已由
TPM credential 打开；#f 表示未尝试或失败（调用方回退密码）。
TPM2-BIN/CRYPTSETUP-BIN 为 store 中的可执行文件路径。"
  (catch #t
    (lambda ()
      ;; ── cmdline 门控：Recovery 与显式禁用都跳过（双保险）
      (let ((raw-mode (proc-cmdline-option "rootmode"))
            (tpm-off (proc-cmdline-option "guixcfg.tpm-unlock")))
        (when (or (and tpm-off (string=? tpm-off "0"))
                  (and raw-mode (string-prefix? "recovery" raw-mode)))
          (throw 'tpm-skip "cmdline 禁用（Recovery/显式）")))
      
      ;; ── TPM 设备可用性（生产 /dev/tpmrm0）
      (unless (file-exists? "/dev/tpmrm0")
        (throw 'tpm-skip "无 /dev/tpmrm0"))
      
      ;; ── 设备发现：PARTLABEL 固定事实（model.scm）
      (let ((system-part (partname-device "system"))
            (esp-part (partname-device "esp")))
        (unless (and system-part esp-part)
          (throw 'tpm-skip "未找到 system/esp 分区"))
        (format #t "TPM: system=~a esp=~a~%" system-part esp-part)
        
        ;; ── 挂 ESP，读机器级 tpm2/ 材料（固定路径，无 slot 概念）
        (mkdir-p %esp-tpm-mount)
        (mount esp-part %esp-tpm-mount "vfat" 0 "")
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (let* ((tpm2-dir (string-append %esp-tpm-mount "/" %esp-tpm2-dir))
                  (seal-pub (string-append tpm2-dir "/seal.pub"))
                  (seal-priv (string-append tpm2-dir "/seal.priv")))
             (unless (and (file-exists? seal-pub) (file-exists? seal-priv))
               (throw 'tpm-skip "ESP 缺少 tpm2 材料"))
             (format #t "TPM: tpm2 材料就绪，尝试自动解锁~%")
             
             ;; ── unseal：重建 SRK → load sealed → policy session
             ;;    （实际 PCR7）→ unseal stdout 管道直连 cryptsetup。
             ;;    每步 catch 并归类（failure 阶段区分），boot console
             ;;    只输出一行分类日志。
             (let* ((workdir "/run/guixcfg/tpm2-initrd")
                    (primary (string-append workdir "/primary.ctx"))
                    (seal-ctx (string-append workdir "/seal.ctx"))
                    (sess (string-append workdir "/policy.session.ctx")))
               (mkdir-p workdir)
               (catch #t
                 (lambda ()
                   (tpm2-createprimary! %tpm2-tools-tcti tpm2-bin #:out primary))
                 (lambda (k . a) (throw 'tpm-fail "SRK 创建失败")))
               (catch #t
                 (lambda ()
                   (tpm2-load-sealed! %tpm2-tools-tcti tpm2-bin
                                      primary seal-pub seal-priv
                                      #:out seal-ctx))
                 (lambda (k . a)
                   (throw 'tpm-fail "sealed object 加载失败（artifact 无效或 TPM 状态不符）")))
               (tpm2-start-policy-session! %tpm2-tools-tcti tpm2-bin
                                           #:out sess)
               (tpm2-policy-pcr-session! %tpm2-tools-tcti tpm2-bin sess
                                         #:pcr "sha256:7")
               (catch #t
                 (lambda ()
                   (let ((secret-port
                          (tpm2-unseal! %tpm2-tools-tcti tpm2-bin
                                        seal-ctx sess)))
                     ;; unseal stdout → cryptsetup stdin
                     (let ((crypt-port
                            (open-pipe* OPEN_WRITE cryptsetup-bin
                                        "open" "--type" "luks"
                                        "--key-file=-"
                                        system-part
                                        %luks-mapper-name)))
                       (let loop ()
                         (let ((bv (get-bytevector-n secret-port 4096)))
                           (unless (eof-object? bv)
                             (put-bytevector crypt-port bv)
                             (loop))))
                       (let ((status (close-pipe crypt-port)))
                         (close-port secret-port)
                         (unless (zero? (status:exit-val status))
                           (throw 'tpm-fail "cryptsetup 拒绝 credential"))))
                     (tpm2-flush-session! %tpm2-tools-tcti tpm2-bin sess)
                     (format #t "TPM: LUKS 自动解锁成功~%")
                     #t)))
               (lambda (k . a)
                 (if (eq? k 'tpm-fail)
                   (apply throw k a)
                   (throw 'tpm-fail "PCR policy 不匹配或 TPM 命令失败"))))))
         (lambda ()
           (false-if-exception (umount %esp-tpm-mount))))))
    (lambda (key . args)
      ;; boot console 保持短：只输出一行分类日志（skip vs failure +
      ;; 原因/阶段），不打印 stack trace。
      (cond
        ((eq? key 'tpm-skip)
         (format #t "TPM: 跳过（~a），回退密码~%"
                 (and (pair? args) (car args))))
        ((eq? key 'tpm-fail)
         (format #t "TPM: 失败（~a），回退密码~%"
                 (and (pair? args) (car args))))
        (else
         (format #t "TPM: 失败（TPM 命令/未知），回退密码~%")))
      #f)))
