;;; boot device resolver 的单元测试：
;;;   - hex->bytes 往返（ESP UUID 文件内容 = 规范化 hex 字符串，
;;;     initrd 侧 hex->bytes 还原必须与 uuid-bytevector 一致）
;;;   - resolve-esp-device 的 sibling 语义（0/1/多 PARTNAME=esp）
;;;   - normalize-luks-uuid 规范化与拒绝
;;;   - read-luks-uuid-from-esp 的运行时读取与 fail-closed 分支

(use-modules (guixcfg boot device-resolver)
             ((guixcfg security tpm2 tpm2-tools) #:prefix tpm2:)
             (gnu system uuid)                  ; uuid、uuid-bytevector
             (guix build utils)                 ; mkdtemp、delete-file-recursively
             (srfi srfi-64))

(test-begin "device-resolver")

;; ── hex->bytes 往返 + config identity（4.2 gexp 边界）────────
(test-equal "hex->bytes basic"
            #vu8(18 52 86 120 154 188 222 240)
            (hex->bytes "123456789abcdef0"))

(let* ((test-uuid (uuid "12345678-1234-1234-1234-123456789abc"))
       (bv (uuid-bytevector test-uuid))
       (hex (tpm2:bytes->hex bv)))
  ;; ESP 文件内容（规范化 hex）→ initrd 侧 hex->bytes 还原——
  ;; 必须与 uuid-bytevector 完全一致
  (test-equal "ESP file content round-trips to uuid-bytevector"
              bv
              (hex->bytes hex))
  (test-equal "hex is 32 hex chars (no dashes)"
              32 (string-length hex)))

;; ── resolve-esp-device：sibling 语义（0/1/多）──────────────
(let ((dir (mkdtemp "/tmp/guixcfg-resolver-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (let* ((sysfs (string-append dir "/sysfs/block"))
            (real (string-append dir "/real/vda"))
            (vda (string-append sysfs "/vda")))
       (mkdir-p vda)
       (mkdir-p real)
       ;; system partition 的 sysfs 项（symlink 到 realpath，模拟
       ;; /sys/block/vda2 -> /sys/devices/.../vda/vda2）
       (symlink (string-append real "/vda2") (string-append sysfs "/vda2"))
       
       ;; 0 个 esp → error
       (test-assert "0 sibling ESPs -> error"
                    (catch #t
                      (lambda ()
                        (resolve-esp-device "/dev/vda2" #:sysfs sysfs)
                        #f)
                      (lambda (k . a) #t)))
       
       ;; 1 个 esp（vda1）
       (mkdir-p (string-append vda "/vda1"))
       (call-with-output-file (string-append vda "/vda1/uevent")
                              (lambda (port)
                                (display "PARTNAME=esp\n" port)))
       (test-equal "1 sibling ESP -> used"
                   "/dev/vda1"
                   (resolve-esp-device "/dev/vda2" #:sysfs sysfs))
       
       ;; 另一个 disk 上的 esp 不影响（sibling 限定）
       (mkdir-p (string-append sysfs "/vdb"))
       (mkdir-p (string-append sysfs "/vdb/vdb1"))
       (call-with-output-file (string-append sysfs "/vdb/vdb1/uevent")
                              (lambda (port)
                                (display "PARTNAME=esp\n" port)))
       (test-equal "other disk's ESP does not affect this disk"
                   "/dev/vda1"
                   (resolve-esp-device "/dev/vda2" #:sysfs sysfs))
       
       ;; 多个 esp（vda1 + vda3）→ error（放在最后：会改变 vda 盘的
       ;; esp 数量，必须先于其他 disk 测试完成断言）
       (mkdir-p (string-append vda "/vda3"))
       (call-with-output-file (string-append vda "/vda3/uevent")
                              (lambda (port)
                                (display "PARTNAME=esp\n" port)))
       (test-assert "multiple sibling ESPs -> error"
                    (catch #t
                      (lambda ()
                        (resolve-esp-device "/dev/vda2" #:sysfs sysfs)
                        #f)
                      (lambda (k . a) #t)))))
   
   (lambda ()
     (delete-file-recursively dir))))

;; ── resolve-system-device：错误 UUID fail-closed（D2）─────────
(test-assert "wrong UUID refused (D2)"
             (catch #t
               (lambda ()
                 (resolve-system-device "ffffffffffffffffffffffffffffffff" #:tries 0)
                 #f)
               (lambda (k . a) #t)))

;; ── normalize-luks-uuid（ESP UUID 文件写/读两侧的共享规范化）──
(test-equal "normalize-luks-uuid: dashed -> 32 hex"
            "12345678123412341234123456789abc"
            (normalize-luks-uuid "12345678-1234-1234-1234-123456789abc"))
(test-equal "normalize-luks-uuid: already normalized"
            "12345678123412341234123456789abc"
            (normalize-luks-uuid "12345678123412341234123456789abc"))
(test-equal "normalize-luks-uuid: uppercase accepted"
            "12345678123412341234123456789abc"
            (normalize-luks-uuid "12345678-1234-1234-1234-123456789ABC"))
(test-assert "normalize-luks-uuid: wrong length rejected"
             (not (normalize-luks-uuid "1234")))
(test-assert "normalize-luks-uuid: non-hex rejected"
             (not (normalize-luks-uuid "zzzz5678-1234-1234-1234-123456789abc")))
(test-assert "normalize-luks-uuid: non-string rejected"
             (not (normalize-luks-uuid 42)))

;; ── read-luks-uuid-from-esp：假 sysfs + 假 mount（symlink EFI 目录
;;    模拟挂载），覆盖 fail-closed 各分支。
(let ((dir (mkdtemp "/tmp/guixcfg-esp-uuid-XXXXXX")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (define sysfs (string-append dir "/sys/block"))
     (define mp (string-append dir "/mnt"))
     (define mapping '())   ; ("/dev/vda1" . content-dir) ...
     (define (add-esp! disk part uuid-content)
       (mkdir-p (string-append sysfs "/" disk "/" part))
       (call-with-output-file (string-append sysfs "/" disk "/" part "/uevent")
                              (lambda (p) (display "PARTNAME=esp\n" p)))
       (let ((content (string-append dir "/esp-" part)))
         (mkdir-p content)
         (when uuid-content
           (mkdir-p (string-append content "/EFI/Guix"))
           (call-with-output-file (string-append content "/EFI/Guix/luks-uuid")
                                  (lambda (p) (display uuid-content p) (newline p))))
         (set! mapping (acons (string-append "/dev/" part) content mapping))))
     (define (fake-mount dev target type flags data)
       (let ((src (assoc-ref mapping dev)))
         (if (and src (file-exists? (string-append src "/EFI")))
           (symlink (string-append src "/EFI") (string-append target "/EFI"))
           (throw 'mount-failed dev))))
     (define (fake-umount target)
       (when (file-exists? (string-append target "/EFI"))
         (delete-file (string-append target "/EFI"))))
     (define (read-uuid)
       (read-luks-uuid-from-esp #:sysfs sysfs
                                #:mount-point mp
                                #:mount-fn fake-mount
                                #:umount-fn fake-umount))
     
     ;; 无任何 ESP 分区 → fail-closed
     (test-assert "no ESP partition at all -> error"
                  (catch #t
                    (lambda () (read-uuid) #f)
                    (lambda (k . a) #t)))
     
     ;; 一个 ESP 带合法 dashed UUID → 规范化读取
     (add-esp! "vda" "vda1" "12345678-1234-1234-1234-123456789abc")
     (test-equal "single ESP with valid UUID -> normalized hex"
                 "12345678123412341234123456789abc"
                 (read-uuid))
     
     ;; 第二个 ESP（另一盘）内容一致 → 仍可读
     (add-esp! "vdb" "vdb1" "12345678123412341234123456789abc")
     (test-equal "two ESPs with identical UUID -> accepted"
                 "12345678123412341234123456789abc"
                 (read-uuid))
     
     ;; 内容冲突 → fail-closed
     (call-with-output-file (string-append dir "/esp-vdb1/EFI/Guix/luks-uuid")
                            (lambda (p) (display "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" p) (newline p)))
     (test-assert "conflicting UUIDs across ESPs -> error"
                  (catch #t
                    (lambda () (read-uuid) #f)
                    (lambda (k . a) #t)))
     
     ;; 内容非法 → fail-closed（不是静默跳过）
     (call-with-output-file (string-append dir "/esp-vdb1/EFI/Guix/luks-uuid")
                            (lambda (p) (display "not-a-uuid" p) (newline p)))
     (test-assert "invalid UUID content -> error"
                  (catch #t
                    (lambda () (read-uuid) #f)
                    (lambda (k . a) #t)))
     
     ;; 全部 ESP 都没有文件 → fail-closed
     (delete-file-recursively (string-append dir "/esp-vda1/EFI"))
     (delete-file-recursively (string-append dir "/esp-vdb1/EFI"))
     (test-assert "no UUID file on any ESP -> error"
                  (catch #t
                    (lambda () (read-uuid) #f)
                    (lambda (k . a) #t))))
   (lambda ()
     (delete-file-recursively dir))))

(test-end)
