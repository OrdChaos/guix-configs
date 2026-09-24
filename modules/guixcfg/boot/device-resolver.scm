;;; initrd boot device resolver：LUKS UUID authoritative。
;;;
;;; 规定：
;;;   LUKS UUID   = system volume authoritative identity（运行时从 ESP
;;;                 %esp-luks-uuid-file 读取——initrd derivation 不编入
;;;                 UUID；见 (guixcfg boot layout)）
;;;   PARTLABEL   = semantic role（ESP 候选发现；UUID 仍是最终校验）
;;;
;;; 只依赖低层 guile、(gnu build file-systems)（find-partition-by-luks-uuid
;;; 扫描块设备 LUKS 头）、(guix build syscalls)/(guix build utils) 与
;;; (guixcfg storage model)/(guixcfg boot layout)（纯数据常量，本就随
;;; tpm-unlock 进 initrd 闭包）——不拉 (guix gexp)/(guix packages)/
;;; (guix utils)：guile-static-initrd 下这些模块进 initrd 闭包会因
;;; strverscmp dlsym 失败而构建失败（实测）。

(define-module (guixcfg boot device-resolver)
               #:use-module ((gnu build file-systems)
                             #:select (find-partition-by-luks-uuid))
               #:use-module (guixcfg storage model)     ; %esp-partlabel（纯数据，initrd 闭包安全）
               #:use-module (guixcfg boot layout)       ; %esp-luks-uuid-file（纯数据，同上）
               #:use-module (guix build syscalls)       ; mount、umount、MS_RDONLY
               #:use-module (guix build utils)          ; mkdir-p
               #:use-module (rnrs bytevectors)        ; make-bytevector
               #:use-module (ice-9 ftw)               ; scandir
               #:use-module (ice-9 rdelim)            ; read-line
               #:use-module (srfi srfi-1)             ; filter-map、append-map、any
               #:use-module (srfi srfi-13)            ; string-prefix?/string-contains
               #:export (hex->bytes
                         normalize-luks-uuid
                         resolve-system-device
                         resolve-esp-device
                         esp-partition-devices
                         read-luks-uuid-from-esp))

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

(define (hex-digit? c)
  (or (char-numeric? c)
      (and (char>=? c #\a) (char<=? c #\f))))

(define (normalize-luks-uuid s)
  "把带/不带连字符的 LUKS UUID 字符串规范化为 32 位小写 hex；
非法（长度/字符不对、非字符串）返回 #f。"
  (and (string? s)
       (let ((hex (string-downcase
                   (string-filter (lambda (c) (not (char=? c #\-))) s))))
         (and (= 32 (string-length hex))
              (string-every hex-digit? hex)
              hex))))

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
分区条目位置随内核版本变化（实测）：
  - 旧内核：/sys/block/<part> 是独立 symlink（realpath 到 .../vda/vda2）
  - 新内核（linux 7.x）：/sys/block 只列 disk（vda），分区在
    /sys/block/<disk>/<part> 与 /sys/class/block/<part>（symlink 到
    ../../devices/.../vda/vda2，dirname 即 disk）
两个位置都尝试；disk 名取 realpath 的 dirname basename。
SYSFS 是 /sys/block 注入点；class/block fallback 从同一 sysfs 根推导，
测试注入时不读宿主真实 /sys。"
  (define (disk-of-link link)
    (and (false-if-exception (lstat link))  ; symlink 本身存在（不跟随）
         (let ((real (readlink link)))
           (and (string? real)
                (let* ((dir (dirname real))
                       (disk (basename dir)))
                  (and (not (string=? disk partition)) disk))))))
  (or (disk-of-link (string-append sysfs "/" partition))
      (disk-of-link (string-append (dirname sysfs) "/class/block/" partition))))

(define* (esp-partition-devices #:key (sysfs "/sys/block"))
         "所有 disk 上 PARTNAME=%esp-partlabel 的分区（/dev/<名>）列表。
与 resolve-esp-device 的 sibling 限定不同：这里在还不知道 LUKS UUID
之前做候选发现，扫描全部 disk（sysfs 顶层即 disk 列表）。"
         (append-map
          (lambda (disk)
            (if (string-prefix? "." disk)
              '()
              (partname-devices-on-disk sysfs disk %esp-partlabel)))
          (or (scandir sysfs) '())))

(define %esp-uuid-mount "/run/guixcfg-esp-uuid")

(define* (read-luks-uuid-from-esp #:key (sysfs "/sys/block")
                                  (mount-point %esp-uuid-mount)
                                  (mount-fn mount)
                                  (umount-fn umount))
         "从 ESP 的 %esp-luks-uuid-file 读取 LUKS UUID，返回规范化 32 位小写
hex 字符串。逐个只读挂载 ESP 候选分区（挂不上的跳过，如异质文件
系统）；文件缺失的分区不计；0 个文件或多个不同值都 error
（fail-closed）。返回值之后仍须经 find-partition-by-luks-uuid 扫盘
验证——UUID 是权威身份，ESP 文件只是它的载体。"
         (let ((values
                (filter-map
                 (lambda (esp)
                   (and (catch #t
                          (lambda ()
                            (mkdir-p mount-point)
                            (mount-fn esp mount-point "vfat" MS_RDONLY "")
                            #t)
                          (lambda (key . args) #f))
                        (dynamic-wind
                         (lambda () #t)
                         (lambda ()
                           (let ((file (string-append mount-point "/"
                                                      %esp-luks-uuid-file)))
                             (and (file-exists? file)
                                  (or (normalize-luks-uuid
                                       (string-trim-both
                                        (call-with-input-file file read-line)))
                                      (error "invalid LUKS UUID in ESP file"
                                             file)))))
                         (lambda ()
                           (false-if-exception (umount-fn mount-point))))))
                 (esp-partition-devices #:sysfs sysfs))))
           (cond ((null? values)
                  (error "LUKS UUID file not found on any ESP"
                         %esp-luks-uuid-file))
             ((any (lambda (v) (not (string=? v (car values)))) values)
              (error "conflicting LUKS UUID files across ESPs" values))
             (else (car values)))))

(define* (resolve-esp-device system-device
                             #:key (sysfs "/sys/block"))
         "SYSTEM-DEVICE（/dev/<分区>）的 sibling ESP：parent disk → 只扫该
disk → PARTNAME=%esp-partlabel；0 个或多个 → error。"
         (let* ((partition (basename system-device))
                (disk (partition-parent-disk sysfs partition)))
           (unless disk
             (error "cannot determine parent disk of system partition" system-device))
           (let ((esps (partname-devices-on-disk sysfs disk %esp-partlabel)))
             (case (length esps)
               ((0) (error "no PARTNAME=esp on system disk" disk))
               ((1) (car esps))
               (else (error "multiple PARTNAME=esp on system disk" disk esps))))))
