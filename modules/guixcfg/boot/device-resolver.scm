;;; initrd boot device resolver：LUKS UUID authoritative。
;;;
;;; 规定：
;;;   LUKS UUID   = system volume authoritative identity
;;;   PARTLABEL   = semantic role（ESP 只在 system 的 sibling disk 上找）
;;;
;;; 只依赖低层 guile 与 (gnu build file-systems)（find-partition-by-luks-uuid
;;; 扫描块设备 LUKS 头）——不拉 (guix gexp)/(guix packages)/(guix utils)：
;;; guile-static-initrd 下这些模块进 initrd 闭包会因 strverscmp dlsym
;;; 失败而构建失败（实测）。

(define-module (guixcfg boot device-resolver)
               #:use-module (rnrs bytevectors)        ; make-bytevector
               #:use-module (ice-9 ftw)               ; scandir
               #:use-module (ice-9 rdelim)            ; read-line
               #:use-module (srfi srfi-1)             ; filter-map
               #:use-module (srfi srfi-13)            ; string-prefix?/string-contains
               #:export (hex->bytes
                         resolve-system-device
                         resolve-esp-device))

(define (hex->bytes hex)
  "HEX 字符串（小写，偶数长度）→ bytevector。"
  (let* ((hex (string-downcase hex))
         (len (quotient (string-length hex) 2)))
    (let ((bv (make-bytevector len 0)))
      (let loop ((i 0))
        (when (< i len)
          (bytevector-u8-set! bv i
                              (string->number (substring hex (* i 2) (+ (* i 2) 2)) 16))
          (loop (1+ i))))
      bv)))

(define* (resolve-system-device luks-uuid-hex
                                #:key (tries 10) (sleep-secs 1))
         "按 LUKS UUID（config 侧嵌入的 hex 字符串，16 字节）解析系统分区，
返回 /dev/<分区名>。UUID 是权威身份：找不到直接 error，绝不回退
PARTNAME 猜测（配置与磁盘事实不一致时必须失败）。"
         (let loop ((n tries))
           (cond ((<= n 0)
                  (error "system LUKS partition not found by UUID" luks-uuid-hex))
             ((find-partition-by-luks-uuid (hex->bytes luks-uuid-hex)) => identity)
             (else (sleep sleep-secs) (loop (- n 1))))))

(define (partname-devices-on-disk sysfs disk label)
  "返回 /sys/block/DISK 下 PARTNAME=LABEL 的所有分区（/dev/<名>）列表。
只扫描该 disk（sibling 限定），不碰其他盘。"
  (filter-map
   (lambda (part)
     (and (not (string-prefix? "." part))
          (let ((uevent (string-append sysfs "/" disk "/" part "/uevent")))
            (and (file-exists? uevent)
                 (call-with-input-file uevent
                                       (lambda (port)
                                         (let loop ()
                                           (let ((line (read-line port)))
                                             (cond ((eof-object? line) #f)
                                               ((string-contains line (string-append "PARTNAME=" label))
                                                (string-append "/dev/" part))
                                               (else (loop)))))))))))
   (or (scandir (string-append sysfs "/" disk)) '())))

(define (partition-parent-disk sysfs partition)
  "返回分区（如 /dev/vda2）所在 disk 名（vda）或 #f。
/sys/block/<part> 的 realpath 是 /sys/devices/.../vda/vda2。"
  (let ((link (string-append sysfs "/" partition)))
    (and (false-if-exception (lstat link))  ; symlink 本身存在（不跟随）
         (let ((real (readlink link)))
           (and (string? real)
                (let* ((dir (dirname real))
                       (disk (basename dir)))
                  (and (not (string=? disk partition)) disk)))))))

(define* (resolve-esp-device system-device
                             #:key (sysfs "/sys/block"))
         "SYSTEM-DEVICE（/dev/<分区>）的 sibling ESP：parent disk → 只扫该
disk → PARTNAME=esp；0 个或多个 → error。"
         (let* ((partition (basename system-device))
                (disk (partition-parent-disk sysfs partition)))
           (unless disk
             (error "cannot determine parent disk of system partition" system-device))
           (let ((esps (partname-devices-on-disk sysfs disk "esp")))
             (case (length esps)
               ((0) (error "no PARTNAME=esp on system disk" disk))
               ((1) (car esps))
               (else (error "multiple PARTNAME=esp on system disk" disk esps))))))
