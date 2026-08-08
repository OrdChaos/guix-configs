;;; 文件系统声明：LUKS 映射、root、ESP、全部持久子卷。
;;; 由 storage/model.scm 的固定事实生成，不重复手写子卷清单。
;;; 对应 docs/storage.md 第 10–13 章；语义名称（PARTLABEL/mapper 名）见第 19 章。

(define-module (guixcfg system file-systems)
               #:use-module (guixcfg storage model)
               #:use-module (gnu system file-systems)    ; file-system、%base-file-systems
               #:use-module (gnu system mapped-devices)  ; mapped-device、luks-device-mapping
               #:use-module (gnu system uuid)            ; uuid
               #:export (%cryptroot-mapped-devices
                         system-file-systems
                         %swap-spaces))

;; 机器事实（docs/storage.md 第 19 章）：安装器写入，可重新探测，不进 Git。
;; 构建期读取：优先 GUIX_CONFIG_FACTS 环境变量（LiveCD 安装时指向
;; /mnt/persist/...，即 configctl 以后也会用它显式传入），
;; 其次运行系统的固定路径。文件不存在时回退到 by-partlabel
;; （可做 system build 评估，但那样的配置在 initrd 里无法解锁——
;; initrd 没有 udev，by-partlabel 不存在）。
(define %facts-path
  (or (getenv "GUIX_CONFIG_FACTS")
      "/persist/system/facts/host.scm"))

(define %machine-facts
  (if (file-exists? %facts-path)
      (call-with-input-file %facts-path read)
      '()))

(define (machine-fact key)
  (assq-ref %machine-facts key))

;; LUKS 映射：优先用 facts 里的 LUKS UUID——initrd 会扫描块设备匹配
;; LUKS 头，无需 udev 符号链接；没有 facts 时退回固定 PARTLABEL。
(define %cryptroot-source
  (cond ((machine-fact 'luks-uuid) => (lambda (u) (uuid u)))
        (else (string-append "/dev/disk/by-partlabel/" %system-partlabel))))

(define %cryptroot-mapped-devices
  (list (mapped-device
         (source %cryptroot-source)
         (target %luks-mapper-name)
         (type luks-device-mapping))))

(define %mapper-path
  (string-append "/dev/mapper/" %luks-mapper-name))

(define (subvolume-options-string sv)
  "把子卷记录转成 Btrfs 挂载选项字符串：subvol=...,compress=zstd 形式。"
  (string-join (cons (string-append "subvol=" (subvolume-name sv))
                     (subvolume-options sv))
               ","))

(define (persist-subvolume->file-system sv)
  "一个持久子卷的 file-system 声明。/gnu/store 等保存系统本体，
必须 needed-for-boot 且依赖 LUKS 映射。
create-mount-point?：阶段 4 起每个新 root generation 都是空子卷，
挂载点目录必须在挂载时自动创建。check? #f：btrfs 由 CoW 自愈，
不在启动时跑 fsck。"
  (file-system
   (device %mapper-path)
   (mount-point (subvolume-mount-point sv))
   (type "btrfs")
   (options (subvolume-options-string sv))
   (dependencies %cryptroot-mapped-devices)
   (needed-for-boot? #t)
   (create-mount-point? #t)
   (check? #f)))

(define (root-file-system root-subvolume)
  "root 文件系统。ROOT-SUBVOLUME 是子卷名：
阶段 3 用 @root-installing；阶段 4 起由启动流程换成当前 @root-N。"
  (file-system
   (device %mapper-path)
   (mount-point "/")
   (type "btrfs")
   (options (string-append "subvol=" root-subvolume))
   (dependencies %cryptroot-mapped-devices)
   (needed-for-boot? #t)
   (check? #f)))

(define %esp-file-system
  (file-system
   (device (string-append "/dev/disk/by-partlabel/" %esp-partlabel))
   (mount-point "/efi")
   (type "vfat")
   (create-mount-point? #t)   ; 新 root generation 上没有 /efi 目录
   (check? #f)))

(define (system-file-systems root-subvolume)
  "完整文件系统列表（不含 %base-file-systems，由 host 追加）。"
  (cons* (root-file-system root-subvolume)
         %esp-file-system
         (map persist-subvolume->file-system %persist-subvolumes)))

;; Btrfs swapfile（docs/storage.md 第 13.5 节）。
(define %swap-spaces
  (list (swap-space
         (target "/persist/swap/swapfile"))))
