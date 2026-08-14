;;; Recovery promote：userspace confirm 时把部署的 Recovery candidate
;;; 提升为正式 Recovery。
;;;
;;; 核心不变量：部署成功 ≠ 启动成功。部署只产生 candidate（带 system
;;; identity，见 (guixcfg boot uki)）；只有这里（confirm）验证
;;; candidate.system == /run/current-system 后才：
;;;   2. GC root 保护 confirmed system
;;;   3. promote Recovery artifact（槽内 → 稳定路径 EFI/Guix/RECOVERY.EFI）
;;;   4. 更新 limine.conf（Recovery 入口）
;;;   5. 写 boot-state（最终 commit record）
;;;
;;; fail-safe：任何中途失败时旧 Recovery（稳定路径）仍有效；操作幂等
;;; 可重试。Recovery 与 A/B 槽生命周期分开——Recovery 是 confirmed
;;; last-good，不是第三个 A/B 槽。

(define-module (guixcfg boot recovery)
               #:use-module (guix build utils)       ; mkdir-p
               #:use-module (guixcfg boot boot-state) ; write-boot-states!、protect-last-good!
               #:use-module (guixcfg utils atomic-file) ; atomic-replace-file!、atomic-write-file!
               #:use-module (rnrs bytevectors)        ; get-bytevector-all
               #:use-module (ice-9 binary-ports)      ; get-bytevector-all
               #:use-module (ice-9 rdelim)            ; read-line
               #:use-module (srfi srfi-13)           ; string-contains
               #:export (promote-recovery!
                         candidate-meta
                         add-recovery-menu-entry!))

;; 与 (guixcfg boot uki) 部署脚本一致的布局常量。
(define %uki-esp-subdir "EFI/Guix")
(define %recovery-stable "EFI/Guix/RECOVERY.EFI")

(define (read-all-string path)
  "读取整个文件为字符串（guix repl 环境无 get-string-all，用字节读）。"
  (utf8->string (call-with-input-file path
                                      (lambda (p)
                                        (get-bytevector-all p)))))

(define (candidate-meta esp)
  "读取 ESP 上的 candidate 元数据（((system . S) (slot . A|B))）或 #f。"
  (let ((path (string-append esp "/" %uki-esp-subdir "/candidate.scm")))
    (and (file-exists? path)
         (false-if-exception
          (call-with-input-file path read)))))

(define (add-recovery-menu-entry! esp)
  "limine.conf 缺 Recovery 入口时追加（指向稳定路径），原子替换。"
  (let ((config (string-append esp "/limine.conf")))
    (when (file-exists? config)
      (let ((content (read-all-string config)))
        (unless (string-contains content "RECOVERY.EFI")
          (atomic-write-file! config
                              (lambda (port)
                                (display content port)
                                (display (string-append
                                          "\n/GNU Guix (Recovery)\n"
                                          "    protocol: efi_chainload\n"
                                          "    image_path: boot():/EFI/Guix/RECOVERY.EFI\n")
                                         port))))))))

(define* (promote-recovery! esp generation command-line
                            #:key (current-system '%resolve)
                            (boot-states-path %boot-states-path)
                            (gc-root "/var/guix/gcroots/guixcfg"))
  "把 ESP 上的 Recovery candidate 提升为正式 Recovery；GENERATION 与
COMMAND-LINE 是当前启动的 Guix generation 与确认 cmdline（boot-state
写入用）。boot-state 总是记录当前确认的 last-good；candidate 与当前
系统不一致时只跳过 artifact/菜单 promote（旧 Recovery 保持有效）。
fail-closed：/run/current-system 无法解析为有效 store identity 时
中止整个 confirm——不更新 GC root、不 promote、不写 boot-state；
绝不以“跳过”日志继续并写入无效 identity。
CURRENT-SYSTEM/BOOT-STATES-PATH/GC-ROOT 为测试注入点（生产调用不传，
分别解析 /run/current-system、用 %boot-states-path 与生产 GC root）。"
  (let* ((current (if (eq? current-system '%resolve)
                    (false-if-exception
                     (canonicalize-path "/run/current-system"))
                    current-system))
         (meta (candidate-meta esp))
         (candidate-system (and meta (assq-ref meta 'system)))
         (match? (and current candidate-system
                      (string=? candidate-system current))))
    (unless (and current (string-prefix? "/gnu/store/" current))
      (error "recovery: 无法解析 /run/current-system 为有效 identity，\
中止 confirm（fail-closed）"))
    (when (and meta (not match?))
      (format #t "recovery: candidate（~a）与当前系统（~a）不一致，跳过 promote~%"
              candidate-system current))
    ;; 2. GC root：保护当前确认的 last-good system（guix gc /
    ;;    delete-generations 不回收 Recovery closure）。
    (protect-last-good! current #:root gc-root)
    (when match?
      ;; 3. promote artifact（槽内 candidate → 稳定路径，原子替换）
      (let* ((slot (assq-ref meta 'slot))
             ;; candidate.scm 里 slot 是符号（(slot . A)）；string-append
             ;; 需要字符串，兼容两种写法。
             (slot-str (if (symbol? slot) (symbol->string slot) slot))
             (slot-uki (string-append esp "/" %uki-esp-subdir
                                      "/" slot-str "/RECOVERY.EFI"))
             (stable-uki (string-append esp "/" %recovery-stable)))
        (if (file-exists? slot-uki)
          (begin
           (mkdir-p (dirname stable-uki))
           (atomic-replace-file! slot-uki stable-uki)
           (format #t "recovery: 已提升 ~a（槽 ~a）~%" candidate-system slot))
          (format #t "recovery: candidate UKI 缺失（~a），跳过 promote~%" slot-uki)))
      ;; 4. limine.conf 加 Recovery 入口（如果缺）
      (add-recovery-menu-entry! esp))
    ;; 5. boot-state（最终 commit record；总是记录当前确认的 last-good）
    (write-boot-states! boot-states-path generation command-line
                        #:system current)
    #t))
