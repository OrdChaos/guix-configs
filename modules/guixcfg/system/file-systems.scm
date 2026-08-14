;;; 文件系统声明：LUKS 映射、root、ESP、全部持久子卷。
;;; 由 storage/model.scm 的固定事实生成，不重复手写子卷清单。
;;; 对应 docs/storage.md 第 10–13 章；语义名称（PARTLABEL/mapper 名）见第 19 章。

(define-module (guixcfg system file-systems)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg boot tpm-unlock)      ; tpm-unlock-in-initrd
               #:use-module (virelith packages tpm2)        ; tpm2-tools-compat
               #:use-module (gnu system file-systems)    ; file-system、%base-file-systems
               #:use-module (gnu system mapped-devices)  ; mapped-device、mapped-device-kind
               #:use-module (gnu system uuid)            ; uuid、uuid-bytevector
               #:use-module (guix gexp)                  ; file-append
               #:use-module (gnu packages cryptsetup)    ; cryptsetup-static
               #:use-module (srfi srfi-1)                ; every、first
               #:export (cryptroot-mapped-devices
                         %ephemeral-root-file-system
                         system-file-systems
                         %swap-spaces))

;; 机器事实（docs/storage.md 第 19 章）：安装器写入，可重新探测，不进 Git。
;; 构建期读取，路径解析规则：
;;   1. GUIX_CONFIG_FACTS（非空）→ 显式 override，必须存在且格式合法，
;;      否则立即报错——显式指定不允许静默忽略；
;;   2. 否则 /persist/system/facts/host.scm 存在 → 自动使用（已安装系统
;;      reconfigure 无需环境变量）；
;;   3. 否则 → 无 machine facts（boot-critical fact 缺失时在构造
;;      mapped-device 处 fail-closed，不回退 by-partlabel）。
(define %default-machine-facts-path
  "/persist/system/facts/host.scm")

(define (regular-file? path)
  "PATH 存在且是普通文件（目录等显式拒绝）。"
  (and (file-exists? path)
       (eq? (stat:type (stat path)) 'regular)))

(define (resolve-facts-path override default)
  "解析 facts 路径（纯函数，便于测试）。OVERRIDE 是 GUIX_CONFIG_FACTS
的值（#f 或空串 = 未设置）。返回实际路径或 #f（无 facts）。"
  (cond
    ((and override (not (string-null? override)))
     (cond
       ((regular-file? override) override)
       ((file-exists? override)
        (error "GUIX_CONFIG_FACTS 指向的不是普通文件:" override))
       (else
        (error "GUIX_CONFIG_FACTS 指向的文件不存在:" override))))
    ((regular-file? default) default)
    ((file-exists? default)
     (error "默认 machine facts 路径不是普通文件:" default))
    (else #f)))

(define (machine-facts-path)
  (resolve-facts-path (getenv "GUIX_CONFIG_FACTS") %default-machine-facts-path))

(define (facts-alist? x)
  (and (list? x) (every pair? x)))

(define (load-machine-facts path)
  "读取并校验 facts 文件：必须是可 read 的 alist，否则显式报错。"
  (let ((facts (catch #t
                 (lambda ()
                   (call-with-input-file path read))
                 (lambda (key . args)
                   (error "machine facts 文件无法解析:" path key args)))))
    (unless (facts-alist? facts)
      (error "machine facts 文件格式非法（应为 alist）:" path))
    facts))

;; 惰性求值：模块加载阶段不执行任何 I/O 或校验——guile 的
;; resolve-module 会吞掉模块加载失败时的原始错误并留下半成品模块，
;; 依赖方（hosts/vm.scm）只会看到 unbound variable。所有 facts 读取
;; 与校验推迟到首次构造 mapped-device 时（force），届时错误在调用方
;; 求值路径上抛出，信息清晰可诊断。
(define %machine-facts
  (delay (let ((path (machine-facts-path)))
           (if path (load-machine-facts path) '()))))

(define (machine-facts)
  (force %machine-facts))

(define (machine-fact key)
  (assq-ref (machine-facts) key))

(define (require-fact facts key)
  "FACTS 中必须存在 KEY；缺失立即报错（fail-closed）——宁可
reconfigure 失败，也不生成已知 initrd 无法解锁的配置。"
  (or (assq-ref facts key)
      (error "缺少必需的 machine fact:" key
             "拒绝生成可启动系统")))

(define (require-machine-fact key)
  (require-fact (machine-facts) key))

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
                             (ice-9 rdelim)
                             (ice-9 ftw)
                             (ice-9 regex)
                             (ice-9 binary-ports)
                             (ice-9 popen)
                             (rnrs bytevectors)
                             (rnrs io ports)
                             (srfi srfi-13))
                ;; cryptsetup 需要 /run/cryptsetup/（LUKS2 强制 locking）
                (mkdir-p "/run/cryptsetup/")
                ;; 先尝试 TPM 自动解锁；失败走标准交互密码路径。
                (if (tpm-unlock-in-initrd
                     #$(file-append tpm2-tools-compat "/bin")
                     #$(file-append cryptsetup-static "/sbin/cryptsetup"))
                  #t
                  (let* ((source-bv #$(if (uuid? source)
                                        (uuid-bytevector source)
                                        source))
                         ;; 分区发现优先 PARTNAME（/sys/block 扫描，实测
                         ;; 可靠）；UUID 匹配作后备——实测 boot 时嵌入的
                         ;; source-bv 与 initrd 文件内容可能不一致（gexp
                         ;; 序列化边界），不能用它作为唯一发现手段。
                         (partition
                          (or (partname-device "system")
                              (let loop ((tries-left 10))
                                (and (positive? tries-left)
                                     (or (find-partition-by-luks-uuid source-bv)
                                         (begin (sleep 1)
                                                (loop (- tries-left 1))))))
                              (error "LUKS partition not found" source-bv)))
                         (cryptsetup
                          #$(file-append cryptsetup-static "/sbin/cryptsetup")))
                    (format #t "TPM 解锁未成功，进入密码解锁~%")
                    (zero? (system*/tty cryptsetup "open" "--type" "luks"
                                        partition #$target))))))))
   (close (lambda (source targets)
            #~(system* #$(file-append cryptsetup-static "/sbin/cryptsetup")
                       "close" #$(first targets))))
   (modules '((guixcfg boot tpm-unlock)
              (rnrs bytevectors)
              (rnrs io ports)
              (ice-9 match)
              (ice-9 rdelim)
              ((gnu build file-systems)
               #:select (find-partition-by-luks-uuid system*/tty))))))

;; LUKS 映射 source：必须用 facts 里的 LUKS UUID——initrd 扫描块设备
;; 匹配 LUKS 头（find-partition-by-luks-uuid），无需 udev 符号链接。
;; 缺少 luks-uuid 时 fail-closed，绝不回退 /dev/disk/by-partlabel/。
;; 函数而非变量：构造时（首次调用）才触发 facts 校验，模块加载不失败。
;; 解锁类型：luks-tpm2-device-mapping——先尝试 TPM2 PCR7 自动解锁，
;; 失败回退标准交互密码（docs/boot.md 第 16.4 节）。
(define (cryptroot-mapped-devices)
  (list (mapped-device
         (source (uuid (require-machine-fact 'luks-uuid)))
         (target %luks-mapper-name)
         (type luks-tpm2-device-mapping))))

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
   (dependencies (cryptroot-mapped-devices))
   (needed-for-boot? #t)
   (create-mount-point? #t)
   (check? #f)))

(define (root-file-system root-subvolume)
  "固定子卷的 root 文件系统（调试用）。
正常系统用 %ephemeral-root-file-system：root generation 由 initrd
在启动时选择（docs/storage.md 第 17 章）。"
  (file-system
   (device %mapper-path)
   (mount-point "/")
   (type "btrfs")
   (options (string-append "subvol=" root-subvolume))
   (dependencies (cryptroot-mapped-devices))
   (needed-for-boot? #t)
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
   (device (string-append "/dev/disk/by-partlabel/" %esp-partlabel))
   (mount-point "/efi")
   (type "vfat")
   (create-mount-point? #t)   ; 新 root generation 上没有 /efi 目录
   (check? #f)))

(define (system-file-systems root-fs)
  "完整文件系统列表（不含 %base-file-systems，由 host 追加）。
ROOT-FS 是根文件系统记录，正常传 %ephemeral-root-file-system。"
  (cons* root-fs
         %esp-file-system
         (map persist-subvolume->file-system %persist-subvolumes)))

;; Btrfs swapfile（docs/storage.md 第 13.5 节）。
(define %swap-spaces
  (list (swap-space
         (target "/persist/swap/swapfile"))))
