;;; boot device resolver 的单元测试：
;;;   - hex->bytes 往返（config identity == runtime identity，Phase 4.2
;;;     gexp UUID boundary 修复的证明：config 侧 bytes->hex 嵌入，
;;;     initrd 侧 hex->bytes 还原必须与 uuid-bytevector 一致）
;;;   - resolve-esp-device 的 sibling 语义（0/1/多 PARTNAME=esp）

(use-modules (guixcfg boot device-resolver)
             ((guixcfg security tpm2 tpm2-tools) #:prefix tpm2:)
             (gnu system uuid)                  ; uuid、uuid-bytevector
             (guix build utils)                 ; mkdtemp、delete-file-recursively
             (srfi srfi-64))

(test-begin "device-resolver")

;; ── hex->bytes 往返 + config identity（4.2 gexp 边界）────────
(test-equal "hex->bytes 基本"
            #vu8(18 52 86 120 154 188 222 240)
            (hex->bytes "123456789abcdef0"))

(let* ((test-uuid (uuid "12345678-1234-1234-1234-123456789abc"))
       (bv (uuid-bytevector test-uuid))
       (hex (tpm2:bytes->hex bv)))
  ;; config 侧：uuid 记录 → bytes->hex（嵌入 initrd 的字符串）
  ;; initrd 侧：hex->bytes 还原——必须与 uuid-bytevector 完全一致
  (test-equal "config identity == runtime identity (4.2)"
              bv
              (hex->bytes hex))
  (test-equal "hex 为 32 个 hex 字符（无连字符）"
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
       (test-assert "0 个 sibling esp → error"
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
       (test-equal "1 个 sibling esp → 使用它"
                   "/dev/vda1"
                   (resolve-esp-device "/dev/vda2" #:sysfs sysfs))
       
       ;; 另一个 disk 上的 esp 不影响（sibling 限定）
       (mkdir-p (string-append sysfs "/vdb"))
       (mkdir-p (string-append sysfs "/vdb/vdb1"))
       (call-with-output-file (string-append sysfs "/vdb/vdb1/uevent")
                              (lambda (port)
                                (display "PARTNAME=esp\n" port)))
       (test-equal "其他 disk 的 esp 不影响本盘解析"
                   "/dev/vda1"
                   (resolve-esp-device "/dev/vda2" #:sysfs sysfs))))
   ;; 多个 esp（vda1 + vda3）→ error
   (mkdir-p (string-append vda "/vda3"))
   (call-with-output-file (string-append vda "/vda3/uevent")
                          (lambda (port)
                            (display "PARTNAME=esp\n" port)))
   (test-assert "多个 sibling esp → error"
                (catch #t
                  (lambda ()
                    (resolve-esp-device "/dev/vda2" #:sysfs sysfs)
                    #f)
                  (lambda (k . a) #t)))
   
   (lambda ()
     (delete-file-recursively dir))))

(test-end)
