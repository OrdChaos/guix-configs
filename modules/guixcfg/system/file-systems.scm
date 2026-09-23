;;; 文件系统声明：LUKS 映射、root、ESP、全部持久子卷。
;;; 由 storage/model.scm 的固定事实生成，不重复手写子卷清单。
;;; 对应 docs/architecture/storage.md；语义名称（PARTLABEL/mapper 名）见固定命名事实一节。

(define-module (guixcfg system file-systems)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg boot layout)       ; %esp-mount-point（ESP 布局 authority）
               #:use-module (guixcfg boot tpm-unlock)      ; tpm-unlock-in-initrd
               #:use-module (virelith packages tpm2)        ; tpm2-tools-compat
               #:use-module (guixcfg boot device-resolver) ; resolve-system-device
               #:use-module (gnu system file-systems)    ; file-system、%base-file-systems
               #:use-module (gnu system mapped-devices)  ; mapped-device、mapped-device-kind
               #:use-module (guix gexp)                  ; file-append
               #:use-module (gnu packages cryptsetup)    ; cryptsetup-static
               #:use-module (srfi srfi-1)                ; every、first
               #:export (cryptroot-mapped-devices
                         %ephemeral-root-file-system
                         system-file-systems
                         %swap-spaces))

;; LUKS UUID 不进 OS derivation：mapped-device source 是固定哨兵
;; %cryptroot-source，真实 UUID 由 initrd 运行时从 ESP 的
;; %esp-luks-uuid-file 读取（(guixcfg boot device-resolver)）——
;; 这样不同机器/不同安装求值出的 initrd/system derivation 逐字节
;; 相同，offline ISO 内预构建的产物可直接复用（零重建、零下载）。
;; facts 机制（(guixcfg system machine-facts)）仍存在于 install/
;; enroll/deploy 的校验路径，但不再参与 OS 构造。

;;; PCR7-aware mapped-device-kind：open 先试 TPM（tpm-unlock-in-initrd，
;;; 见 (guixcfg boot tpm-unlock)——initrd 运行时模块），失败走与
;;; luks-device-mapping 相同的分区发现（find-partition-by-luks-uuid
;;; 10 秒重试）+ cryptsetup 交互解锁。close 用标准 cryptsetup close。
;;;
;;; 本 kind 定义在 config 侧（本模块不进 initrd 闭包），因此可以
;;; import (guix gexp)/(gnu packages …)；进入 initrd 的只有
;;; modules 字段列出的运行时模块（initrd 闭包若含 (guix gexp)/
;;; (guix utils) 会导致 guile-static-initrd 构建失败——strverscmp
;;; dlsym 无法解析，实测）。
(define luks-tpm2-device-mapping
  (mapped-device-kind
   (open (lambda (source targets)
           (let ((target (first targets)))
             #~(begin
                (use-modules (gnu build file-systems)   ; system*/tty
                             (guix build utils)         ; mkdir-p
                             (guix build syscalls)      ; mount、umount
                             (guixcfg boot device-resolver) ; resolve-system-device、read-luks-uuid-from-esp
                             (ice-9 rdelim)
                             (ice-9 ftw)
                             (ice-9 regex)
                             (ice-9 binary-ports)
                             (ice-9 popen)
                             (rnrs bytevectors)
                             (rnrs io ports)
                             (srfi srfi-13))
                ;; cryptroot 的权威身份：ESP 上 %esp-luks-uuid-file 的
                ;; 运行时内容（install/esp-uuid activation 写）。
                ;; 不嵌 config 侧值——UUID 进 gexp 会让 initrd
                ;; derivation 随机器变化，offline ISO 被迫重建 initrd
                ;; 并下载整条构建闭包（实测约 290MB）。
                ;; 用 let* 而非 define：guile 3.0.9（raw-initrd builder 的
                ;; guile-final）的 psyntax 不允许 begin 内 use-modules 之后
                ;; 出现 define（definition in expression context），实测。
                (let* ((source-hex (read-luks-uuid-from-esp)))
                  ;; cryptsetup 需要 /run/cryptsetup/（LUKS2 强制 locking）
                  (mkdir-p "/run/cryptsetup/")
                  ;; 先尝试 TPM 自动解锁；失败走标准交互密码路径。
                  ;; TPM 与密码回退共享同一 resolver（UUID 权威，4.4）。
                  (if (tpm-unlock-in-initrd
                       #$(file-append tpm2-tools-compat "/bin")
                       #$(file-append cryptsetup-static "/sbin/cryptsetup")
                       source-hex)
                    #t
                    (let* ((partition (resolve-system-device source-hex))
                           (cryptsetup
                            #$(file-append cryptsetup-static "/sbin/cryptsetup")))
                      (format #t "TPM unlock unsuccessful; falling back to passphrase~%")
                      ;; console 竞态防御（同 linux-boot 的
                      ;; switch-to-system 重开做法）：pid-1 环境下
                      ;; fd 0/1/2 与 /dev/console 偶发脱钩，实测
                      ;; system*/tty 的 isatty 误判 → login_tty
                      ;; ENOSYS → panic。重开后直接用 system* 继承
                      ;; console（cryptsetup 交互读密码），不再依赖
                      ;; isatty 启发式。
                      (when (file-exists? "/dev/console")
                        (let ((console (open-file "/dev/console" "r+b0")))
                          (for-each close-fdes '(0 1 2))
                          (dup2 (fileno console) 0)
                          (dup2 (fileno console) 1)
                          (dup2 (fileno console) 2)
                          (close-port console)))
                      (zero? (system* cryptsetup "open" "--type" "luks"
                                      partition #$target)))))))))
   (close (lambda (source targets)
            #~(system* #$(file-append cryptsetup-static "/sbin/cryptsetup")
                       "close" #$(first targets))))
   (modules '((guixcfg boot device-resolver)
              (guixcfg boot tpm-unlock)
              (rnrs bytevectors)
              (rnrs io ports)
              (ice-9 match)
              (ice-9 rdelim)
              ((gnu build file-systems)
               #:select (find-partition-by-luks-uuid))))))

;; mapped-device source 的固定哨兵：占位即可（open/close 运行时从 ESP
;; 文件取 UUID，不消费 source）。用常量字符串而非法 uuid——OS
;; derivation 因此与机器 UUID 完全无关。
(define %cryptroot-source "luks-uuid-from-esp")

;; LUKS 映射：initrd 运行时从 ESP %esp-luks-uuid-file 读 UUID，
;; 扫描块设备匹配 LUKS 头（find-partition-by-luks-uuid），无需 udev
;; 符号链接；ESP 文件缺失/非法/多盘冲突时 fail-closed，绝不回退
;; /dev/disk/by-partlabel/ 猜测。
;; 解锁类型：luks-tpm2-device-mapping——先尝试 TPM2 PCR7 自动解锁，
;; 失败回退标准交互密码（docs/architecture/boot.md（TPM2））。
(define (cryptroot-mapped-devices)
  (list (mapped-device
         (source %cryptroot-source)
         (target %luks-mapper-name)
         (type luks-tpm2-device-mapping))))

(define %mapper-path %luks-mapper-path)

(define (subvolume-options-string sv)
  "把子卷记录转成 Btrfs 挂载选项字符串：subvol=...,compress=zstd 形式。"
  (string-join (cons (string-append "subvol=" (subvolume-name sv))
                     (subvolume-options sv))
               ","))

(define (persist-subvolume->file-system sv)
  "一个持久子卷的 file-system 声明。/gnu/store 等保存系统本体，
必须 needed-for-boot 且依赖 LUKS 映射。
create-mount-point?：每个新 root generation 都是空子卷，挂载点目录
必须在挂载时自动创建。check? #f：btrfs 由 CoW 自愈，不在启动时跑 fsck。"
  (file-system
   (device %mapper-path)
   (mount-point (subvolume-mount-point sv))
   (type "btrfs")
   (options (subvolume-options-string sv))
   (dependencies (cryptroot-mapped-devices))
   (needed-for-boot? #t)
   (create-mount-point? #t)
   (check? #f)))

;; 无状态根：initrd 启动时把选中的 @root-N 挂到 staging 目录，
;; 这里把它 bind 成系统根。type "none" + bind-mount 由 boot-system
;; 处理（mount-flags->bit-mask 支持 bind-mount）；内核命令行
;; root=/selected-root 与之一致（路径以 / 开头时原样使用）。
(define %ephemeral-root-file-system
  (file-system
   (device "/selected-root")
   (mount-point "/")
   (type "none")
   (flags '(bind-mount))
   (needed-for-boot? #t)
   (check? #f)))

(define %esp-file-system
  (file-system
   (device (by-partlabel-path %esp-partlabel))
   (mount-point %esp-mount-point)
   (type "vfat")
   (create-mount-point? #t)   ; 新 root generation 上没有 /efi 目录
   (check? #f)))

(define (system-file-systems root-fs)
  "完整文件系统列表（不含 %base-file-systems，由 host 追加）。
ROOT-FS 是根文件系统记录，正常传 %ephemeral-root-file-system。"
  (cons* root-fs
         %esp-file-system
         (map persist-subvolume->file-system %persist-subvolumes)))

;; Btrfs swapfile（docs/architecture/storage.md（Swap））。
(define %swap-spaces
  (list (swap-space
         (target (string-append (persist-mount-point "@persist-swap")
                                "/swapfile")))))
