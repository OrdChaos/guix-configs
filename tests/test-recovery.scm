;;; Recovery promote 的单元测试：candidate 元数据读取与 limine.conf
;;; 菜单追加（端到端 promote 由 T3 clean-state 场景覆盖）。

(use-modules (guixcfg boot recovery)
             (guix build utils)
             (rnrs io ports)            ; get-string-all
             (srfi srfi-64))

;; group 外的测试段（R3/fail-closed/match）需要显式 runner。
;; run-tests.scm 已设置全局 runner——只在单独跑本文件时补上
;; （无 runner 才设，避免覆盖 run-tests 的计数）。
(unless (test-runner-current)
  (test-runner-current (test-runner-simple)))

(test-begin "recovery")

(let ((dir (mkdtemp "/tmp/guixcfg-recovery-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     ;; candidate 元数据：缺失 / 格式合法
     (test-equal "returns #f without candidate"
                 #f (candidate-meta dir))
     (let ((meta-dir (string-append dir "/EFI/Guix")))
       (mkdir-p meta-dir)
       (call-with-output-file (string-append meta-dir "/candidate.scm")
                              (lambda (port)
                                (write '((system . "/gnu/store/abc-system") (slot . "B")) port)
                                (newline port)))
       (let ((meta (candidate-meta dir)))
         (test-equal "candidate system identity"
                     "/gnu/store/abc-system" (assq-ref meta 'system))
         (test-equal "candidate slot" "B" (assq-ref meta 'slot))))
     
     ;; limine.conf 追加 Recovery 入口（指向稳定路径，原子替换）
     (let ((conf (string-append dir "/limine.conf")))
       (call-with-output-file conf
                              (lambda (port)
                                (display "timeout: 3\n\n/GNU Guix\n    protocol: efi_chainload\n    image_path: boot():/EFI/Guix/A/CURRENT.EFI\n" port)))
       (add-recovery-menu-entry! dir)
       (let ((content (call-with-input-file conf get-string-all)))
         (test-assert "appends Recovery entry first time"
                      (string-contains content "image_path: boot():/EFI/Guix/RECOVERY.EFI")))
       ;; 幂等：再次调用不重复追加
       (add-recovery-menu-entry! dir)
       (let ((content (call-with-input-file conf get-string-all)))
         (test-equal "idempotent (no duplicate entries)"
                     1
                     (let loop ((count 0) (pos 0))
                       (let ((i (string-contains content
                                                 "RECOVERY.EFI" pos)))
                         (if i (loop (1+ count) (+ i 1)) count)))))))
   (lambda ()
     (delete-file-recursively dir))))

(test-end)

;; ── promote-recovery!：identity mismatch 拒绝 artifact（R3）────
;; 注入 current-system/boot-states-path/gc-root，不依赖宿主
;; /run/current-system 与 /persist（原实现靠 catch 兜宿主路径错误）。
(let ((dir (mkdtemp "/tmp/guixcfg-recovery-r3-XXXXXX"))
      (boot-state (string-append "/tmp/guixcfg-recovery-r3-state-"
                                 (number->string (getpid))))
      (gc-root (string-append "/tmp/guixcfg-recovery-r3-gc-"
                              (number->string (getpid)))))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append dir "/EFI/Guix/A"))
     (call-with-output-file (string-append dir "/EFI/Guix/A/RECOVERY.EFI")
                            (lambda (p) (display "slot-uki" p)))
     ;; slot 用 symbol（(slot . A)）——string-append 兼容（修复回归）
     (call-with-output-file (string-append dir "/EFI/Guix/candidate.scm")
                            (lambda (p)
                              (write '((system . "/gnu/store/FAKE-SYSTEM") (slot . A)) p)
                              (newline p)))
     ;; candidate.system（FAKE）与 current（REAL）不一致 → 拒绝 promote
     ;; artifact；GC root 与 boot-state 仍记录 REAL（当前系统确认）。
     (promote-recovery! dir 1 "console=ttyS0"
                        #:current-system "/gnu/store/REAL-CURRENT"
                        #:boot-states-path boot-state
                        #:gc-root gc-root)
     (test-assert "identity mismatch refuses artifact promote (R3)"
                  (not (file-exists? (string-append dir "/EFI/Guix/RECOVERY.EFI"))))
     (test-assert "identity mismatch: GC root protects current system"
                  (string=? "/gnu/store/REAL-CURRENT"
                            (readlink (string-append gc-root "/last-good-system"))))
     (let ((state (call-with-input-file boot-state read)))
       (test-equal "identity mismatch: boot-state records current system"
                   "/gnu/store/REAL-CURRENT"
                   (assq-ref (assq-ref state 'last-good) 'system))))
   (lambda ()
     (delete-file-recursively dir)
     (false-if-exception (delete-file boot-state))
     (false-if-exception (delete-file-recursively gc-root)))))

;; ── promote-recovery! fail-closed（Phase 8）──────────────
;; /run/current-system 无法解析为有效 identity → 中止整个 confirm：
;; 不更新 GC root、不 promote artifact、不写 last-good boot-state。
(let ((dir (mkdtemp "/tmp/guixcfg-recovery-fc-XXXXXX"))
      (boot-state (string-append "/tmp/guixcfg-recovery-fc-state-"
                                 (number->string (getpid))))
      (gc-root (string-append "/tmp/guixcfg-recovery-fc-gc-"
                              (number->string (getpid)))))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append dir "/EFI/Guix/A"))
     (call-with-output-file (string-append dir "/EFI/Guix/A/RECOVERY.EFI")
                            (lambda (p) (display "slot-uki" p)))
     (call-with-output-file (string-append dir "/EFI/Guix/candidate.scm")
                            (lambda (p)
                              (write '((system . "/gnu/store/CANDIDATE") (slot . A)) p)
                              (newline p)))
     (let ((err (catch #t
                  (lambda ()
                    (promote-recovery! dir 1 "console=ttyS0"
                                       #:current-system #f
                                       #:boot-states-path boot-state
                                       #:gc-root gc-root)
                    #f)
                  (lambda (k . a)
                    (let ((msg (call-with-output-string
                                (lambda (p) (write a p)))))
                      (string-contains msg "cannot resolve"))))))
       (test-assert "unresolvable identity -> fail-closed abort (throws)" err)
       (test-assert "fail-closed: boot-state not written"
                    (not (file-exists? boot-state)))
       (test-assert "fail-closed: GC root not created"
                    (not (file-exists?
                          (string-append gc-root "/last-good-system"))))
       (test-assert "fail-closed: artifact not promoted"
                    (not (file-exists? (string-append dir "/EFI/Guix/RECOVERY.EFI"))))))
   (lambda ()
     (delete-file-recursively dir)
     (false-if-exception (delete-file boot-state))
     (false-if-exception (delete-file-recursively gc-root)))))

;; ── promote-recovery!：identity match 完整 promote（Phase 8）────
(let ((dir (mkdtemp "/tmp/guixcfg-recovery-ok-XXXXXX"))
      (boot-state (string-append "/tmp/guixcfg-recovery-ok-state-"
                                 (number->string (getpid))))
      (gc-root (string-append "/tmp/guixcfg-recovery-ok-gc-"
                              (number->string (getpid)))))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append dir "/EFI/Guix/A"))
     (call-with-output-file (string-append dir "/EFI/Guix/A/RECOVERY.EFI")
                            (lambda (p) (display "slot-uki" p)))
     (call-with-output-file (string-append dir "/EFI/Guix/candidate.scm")
                            (lambda (p)
                              (write '((system . "/gnu/store/MATCH-SYSTEM") (slot . A)) p)
                              (newline p)))
     (call-with-output-file (string-append dir "/limine.conf")
                            (lambda (p) (display "timeout: 3\n" p)))
     (promote-recovery! dir 1 "console=ttyS0"
                        #:current-system "/gnu/store/MATCH-SYSTEM"
                        #:boot-states-path boot-state
                        #:gc-root gc-root)
     (test-assert "identity match: artifact promoted to stable path"
                  (file-exists? (string-append dir "/EFI/Guix/RECOVERY.EFI")))
     (test-assert "identity match: limine entry added"
                  (string-contains
                   (call-with-input-file (string-append dir "/limine.conf")
                                         get-string-all)
                   "RECOVERY.EFI"))
     (test-assert "identity match: GC root points at confirmed system"
                  (string=? "/gnu/store/MATCH-SYSTEM"
                            (readlink (string-append gc-root "/last-good-system"))))
     (let ((state (call-with-input-file boot-state read)))
       (test-equal "identity match: boot-state records confirmed system"
                   "/gnu/store/MATCH-SYSTEM"
                   (assq-ref (assq-ref state 'last-good) 'system))))
   (lambda ()
     (delete-file-recursively dir)
     (false-if-exception (delete-file boot-state))
     (false-if-exception (delete-file-recursively gc-root)))))
