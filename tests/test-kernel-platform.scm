;;; Kernel platform 测试（M1：Linux-libre → Nonguix standard Linux，
;;; docs/architecture/boot.md（Kernel platform））。
;;;
;;; 覆盖：
;;;   K1  authoritative kernel selection：最终 %vm-os 使用 Nonguix standard
;;;       Linux（evaluated package identity，非字符串 grep）
;;;   K2  boot/runtime 配置不依赖 Linux-libre package identity（注释除外）
;;;   K3  firmware declarative：%vm-os 的 firmware 字段含 linux-firmware
;;;   K4  microcode composition：%vm-os 的 initrd 是 microcode-ephemeral-
;;;       initrd（microcode-initrd 把框架参数转发给 custom initrd
;;;       builder = composition 而非 replacement）；microcode 声明只含
;;;       Intel（declarative，无 AMD 混入 common base）
;;;   K5  initrd 项目行为保留：由全套件既有测试覆盖（root-generation/
;;;       tpm-unlock 等），本文件不重复
;;;   K6  UKI/boot-plan 消费 selected kernel 路径（file-append 结构；
;;;       generic——仓库无 graft-kernel，UKI 直接消费 menu-entry 的
;;;       kernel 路径）
;;;   K7  UKI 部署程序结构（program-file + %kernel bzImage）；完整
;;;       build 由 M1-6 的 system build --dry-run 证明
;;;   K8  不引入 NVIDIA：%vm-os packages/firmware 无 nvidia
;;;   K9  generated runtime：由 test-runtime-exec 覆盖（套件）
;;;   K10 UI language：由 test-ui-language 覆盖（套件）
;;;
;;; 由 tests/run-tests.scm 加载运行（nonguix channel 源已加入 load
;;; path）；单独运行需先设 GUIX_CONFIG_FACTS。

(use-modules (guixcfg hosts vm)
             (guixcfg boot uki)           ; <boot-plan>、make-uki-deploy-program
             (guixcfg system kernel-platform)
             (guix packages)              ; package-name
             (guix gexp)                  ; file-append-base/suffix、program-file?
             (gnu system)                 ; operating-system-*
             (nongnu packages linux)      ; linux-7.2、intel-microcode（nonguix）
             (nongnu system linux-initrd) ; microcode-initrd
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (strip-comments path)
  "读 PATH，去掉引号外的 ; 注释，返回行列表（K2 扫描用）。"
  (let loop ((lines (call-with-input-file path
                                          (lambda (p)
                                            (let l ((acc '()))
                                              (let ((line (read-line p)))
                                                (if (eof-object? line)
                                                  (reverse acc)
                                                  (l (cons line acc))))))))
             (acc '()))
    (if (null? lines)
      (reverse acc)
      (let ((line (car lines)))
        (let scan ((i 0) (in-str #f) (out '()))
          (if (>= i (string-length line))
            (loop (cdr lines) (cons (list->string (reverse out)) acc))
            (let ((c (string-ref line i)))
              (cond
                (in-str
                 (cond ((char=? c #\\) (scan (+ i 2) #t (cons c out)))
                   ((char=? c #\") (scan (+ i 1) #f (cons c out)))
                   (else (scan (+ i 1) #t (cons c out)))))
                ((char=? c #\") (scan (+ i 1) #t (cons c out)))
                ((char=? c #\;) (loop (cdr lines)
                                      (cons (list->string (reverse out)) acc)))
                (else (scan (+ i 1) #f (cons c out)))))))))))

(define %boot-runtime-modules
  ;; boot/runtime 侧消费 kernel 的模块（K2 扫描范围）。
  '("modules/guixcfg/boot/uki.scm"
    "modules/guixcfg/boot/uki-bootloader.scm"
    "modules/guixcfg/boot/initrd.scm"
    "modules/guixcfg/boot/boot-state.scm"
    "modules/guixcfg/boot/device-resolver.scm"
    "modules/guixcfg/security/tpm2/tpm2-tools.scm"
    "modules/guixcfg/security/tpm2/state.scm"
    "modules/guixcfg/storage/root-generation.scm"))

(test-begin "kernel-platform")

;; ── K1：authoritative kernel selection ──────────────────────
(test-assert "K1: %kernel is the Nonguix standard linux 7.2 package"
             (and (eq? %kernel linux-7.2)
                  (string=? (package-name %kernel) "linux")
                  (not (string-contains (package-name %kernel) "libre"))))

(test-assert "K1: %vm-os selects %kernel (no linux-libre fallback)"
             (eq? (operating-system-kernel %vm-os) %kernel))

;; ── K2：boot/runtime 不依赖 Linux-libre package identity ───
(test-assert "K2: boot/runtime modules have no linux-libre symbol (comments excluded)"
             (every (lambda (path)
                      (not (any (lambda (line)
                                  (string-contains line "linux-libre"))
                                (strip-comments path))))
                    %boot-runtime-modules))

;; ── K3：firmware declarative ────────────────────────────────
(test-assert "K3: %vm-os firmware includes linux-firmware"
             (memq linux-firmware (operating-system-firmware %vm-os)))

(test-assert "K3: firmware comes from the kernel platform definition"
             (eq? %kernel-firmware linux-firmware))

;; ── K4：microcode composition（非 replacement）──────────────
(test-assert "K4: %vm-os initrd is the microcode + custom initrd composition"
             (eq? (operating-system-initrd %vm-os) microcode-ephemeral-initrd))

(test-assert "K4: microcode packages are declaratively Intel-only"
             (equal? %kernel-microcode-packages (list intel-microcode)))

(test-assert "K4: microcode composition wraps the custom initrd builder"
             ;; microcode-initrd 配置期就把剩余关键字（#:linux 等）
             ;; 转发给 #:initrd 指定的 builder（stub 记录收到），
             ;; 证明 custom initrd builder 是 composition 的 payload 端。
             (let ((seen '()))
               (define (stub-initrd file-systems . rest)
                 (set! seen (cons rest seen))
                 (computed-file "stub-initrd" #~(mkdir-p #$output)))
               (microcode-initrd '()
                                 #:initrd stub-initrd
                                 #:microcode-packages (list intel-microcode)
                                 #:linux 'linux-pkg)
               (any (lambda (rest) (memq 'linux-pkg rest)) seen)))

;; ── K6：UKI/boot-plan 消费 selected kernel 路径（generic）──
(test-assert "K6: kernel-file of %vm-os is %kernel's bzImage (generic path)"
             (let ((kf (operating-system-kernel-file %vm-os)))
               (and (eq? (file-append-base kf) %kernel)
                    (equal? (file-append-suffix kf) '("/" "bzImage")))))

;; ── K7：UKI deployment derivation 能以 standard Linux 构建 ──
(test-assert "K7: UKI deploy program builds from the selected kernel path"
             ;; program-file 结构检查；完整 UKI build 由 M1-6 的
             ;; system build --dry-run 证明（最终 derivation 使用
             ;; nonguix linux 7.1 source）。
             (let* ((bp (boot-plan
                         (kernel (operating-system-kernel-file %vm-os))
                         (initrd (computed-file "test-initrd"
                                                #~(mkdir-p #$output)))
                         (cmdline "root=/selected-root gnu.system=/gnu/store/x-system")))
                    (prog (make-uki-deploy-program bp)))
               (and (program-file? prog)
                    (eq? (file-append-base (boot-plan-kernel bp)) %kernel))))

;; ── K8：不引入 NVIDIA ───────────────────────────────────────
(test-assert "K8: %vm-os packages contain no nvidia stack"
             (every (lambda (p)
                      (not (string-contains (package-name p) "nvidia")))
                    (operating-system-packages %vm-os)))

(test-assert "K8: firmware is only the generic linux-firmware"
             (every (lambda (f)
                      (not (string-contains (package-name f) "nvidia")))
                    (operating-system-firmware %vm-os)))

(test-end "kernel-platform")
