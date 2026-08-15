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
;;;   - PolicyPCR(实际 PCR7) → tpm2_unseal stdout FD 直连 cryptsetup
;;;     stdin FD（spawn-pipeline，明文不经 Scheme heap）→ cryptsetup
;;;     open --key-file=-
;;;   - 任意失败 → 返回 #f → kind 回退标准交互密码（永不 emergency
;;;     shell）
;;;
;;; 子进程路径：全部走 (guixcfg utils spawn) 的 spawn 原语
;;; （posix_spawn，父进程不 fork——见 (guixcfg utils spawn) 头部注释：
;;; popen/fork + static Guile PID1 组合曾可复现 GC 故障，spawn 为最终
;;; 修复；open-pipe*/invoke 在 initrd 内不可用）。

(define-module (guixcfg boot tpm-unlock)
               #:use-module (guixcfg boot device-resolver) ; resolve-system/esp-device
               #:use-module (guixcfg storage model)        ; %luks-mapper-name
               #:use-module (guixcfg security tpm2 tpm2-tools)
               #:use-module (guixcfg utils spawn)          ; spawn-pipeline
               #:use-module (guix build utils)             ; mkdir-p
               #:use-module (guix build syscalls)          ; mount、umount、mknod
               #:use-module (ice-9 ftw)                    ; scandir
               #:use-module (ice-9 regex)                  ; string-match
               #:use-module (ice-9 rdelim)                 ; read-line
               #:use-module (srfi srfi-1)                  ; first
               #:use-module (srfi srfi-11)                 ; let-values
               #:use-module (srfi srfi-13)                 ; string-tokenize
               #:export (tpm-unlock-in-initrd
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
;;; 设备发现：LUKS UUID authoritative（(guixcfg boot device-resolver)——
;;; system 用 UUID 解析，ESP 是 system 的 sibling；不依赖 udev/partlabel
;;; 猜测）。

;;; ────────────────────────────────────────────────────────────
;;; 决策纯函数（测试用）

(define (tpm-unlock-candidate? recovery? tpm-available? artifacts-present?)
  "是否应尝试 TPM 自动解锁：非 Recovery 且 TPM 可用且 artifact 完整。"
  (and (not recovery?)
       tpm-available?
       artifacts-present?))

;;; ────────────────────────────────────────────────────────────
;;; initrd 解锁尝试

(define (tpm-unlock-in-initrd tpm2-bin cryptsetup-bin luks-uuid-hex)
  "initrd 内的 TPM 自动解锁尝试。返回 #t 表示 LUKS（cryptroot）已由
TPM credential 打开；#f 表示未尝试或失败（调用方回退密码）。
TPM2-BIN/CRYPTSETUP-BIN 为 store 中的可执行文件路径。LUKS-UUID-HEX
为 config 侧嵌入的 system LUKS UUID（hex 字符串，16 字节，无连字符），
UUID 是权威身份。"
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
      (let* ((system-part (resolve-system-device luks-uuid-hex))
             (esp-part (resolve-esp-device system-part)))
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
             (format #t "TPM: tpm2 materials ready, attempting automatic unlock~%")
             
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
                   ;; unseal stdout FD → pipe → cryptsetup stdin FD 直连
                   ;; （spawn-pipeline，父进程只做 pipe/spawn/close/waitpid；
                   ;; 明文不经 Scheme heap。with-tcti 让 tpm2_unseal 继承
                   ;; TPM2TOOLS_TCTI；cryptsetup 不受该变量影响）。
                   (with-tcti %tpm2-tools-tcti
                              (lambda ()
                                (let-values (((unseal-status crypt-status)
                                              (spawn-pipeline
                                               (string-append tpm2-bin "/tpm2_unseal")
                                               "-c" seal-ctx
                                               "-p" (string-append "session:" sess)
                                               "--"
                                               cryptsetup-bin "open" "--type" "luks"
                                               "--key-file=-"
                                               system-part
                                               %luks-mapper-name)))
                                            (unless (zero? crypt-status)
                                              (throw 'tpm-fail "cryptsetup 拒绝 credential"))
                                            (unless (zero? unseal-status)
                                              (throw 'tpm-fail "tpm2_unseal 失败")))))
                   (tpm2-flush-session! %tpm2-tools-tcti tpm2-bin sess)
                   (format #t "TPM: LUKS auto-unlock succeeded~%")
                   #t)
                 (lambda (k . a)
                   (if (eq? k 'tpm-fail)
                     (apply throw k a)
                     (throw 'tpm-fail "PCR policy 不匹配或 TPM 命令失败")))))))
         (lambda ()
           (false-if-exception (umount %esp-tpm-mount))))))
    (lambda (key . args)
      ;; boot console 保持短：只输出一行分类日志（skip vs failure +
      ;; 原因/阶段），不打印 stack trace。
      (cond
        ((eq? key 'tpm-skip)
         (format #t "TPM: skipped (~a); falling back to passphrase~%"
                 (and (pair? args) (car args))))
        ((eq? key 'tpm-fail)
         (format #t "TPM: failed (~a); falling back to passphrase~%"
                 (and (pair? args) (car args))))
        (else
         (format #t "TPM: failed (TPM command/unknown); falling back to passphrase~%")))
      #f)))
