;;; Recovery promote 的单元测试：candidate 元数据读取与 limine.conf
;;; 菜单追加（端到端 promote 由 T3 clean-state 场景覆盖）。

(use-modules (guixcfg boot recovery)
             (guix build utils)
             (srfi srfi-64))

(test-begin "recovery")

(let ((dir (mkdtemp "/tmp/guixcfg-recovery-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     ;; candidate 元数据：缺失 / 格式合法
     (test-equal "无 candidate 时返回 #f"
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
         (test-assert "首次追加 Recovery 入口"
                      (string-contains content "image_path: boot():/EFI/Guix/RECOVERY.EFI")))
       ;; 幂等：再次调用不重复追加
       (add-recovery-menu-entry! dir)
       (let ((content (call-with-input-file conf get-string-all)))
         (test-equal "幂等（不重复追加）"
                     1
                     (let loop ((count 0) (pos 0))
                       (let ((i (string-contains content
                                                 "RECOVERY.EFI" pos)))
                         (if i (loop (1+ count) (+ i 1)) count)))))))
   (lambda ()
     (delete-file-recursively dir))))

(test-end)
