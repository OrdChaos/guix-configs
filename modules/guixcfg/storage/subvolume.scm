;;; Btrfs 子卷创建与挂载：持久子卷、安装期 root、swapfile、最终挂载树。
;;; 对应 docs/storage.md 第 12、13 章；swapfile 约束见第 13.5 节。

(define-module (guixcfg storage subvolume)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage partition)  ; by-partlabel-path
               #:use-module (guix build utils)
               #:use-module (ice-9 format)
               #:export (%btrfs-top-mount
                         execute-mount-top
                         execute-make-subvolume
                         execute-make-root-installing
                         execute-make-swapfile
                         execute-unmount-top
                         execute-mount-root
                         execute-mount-subvolume
                         execute-mount-esp))

;; 创建子卷期间临时挂载 Btrfs 顶层（subvolid=5）的位置。
;; 用 /run（LiveCD 的 tmpfs），不污染目标系统。
(define %btrfs-top-mount "/run/guix-configs-btrfs-top")

(define (mapper-path)
  "LUKS mapper 设备路径。GUIXCFG_TEST_LUKS_MAPPER 仅供 scratch-loopback
集成测试覆盖（见 tests/test-commit-root.scm）；产品默认 /dev/mapper/cryptroot。"
  (or (let ((v (getenv "GUIXCFG_TEST_LUKS_MAPPER")))
        (and v (not (string-null? v)) v))
      (string-append "/dev/mapper/" %luks-mapper-name)))

(define (execute-mount-top)
  (mkdir-p %btrfs-top-mount)
  (invoke "mount" "-o" "subvolid=5" (mapper-path) %btrfs-top-mount))

(define (execute-make-subvolume name)
  (invoke "btrfs" "subvolume" "create"
          (string-append %btrfs-top-mount "/" name)))

(define (execute-make-root-installing name)
  (execute-make-subvolume name))

(define (execute-make-swapfile subvolume-name size-bytes)
  "在子卷 SUBVOLUME-NAME（如 @persist-swap）里创建 swapfile
（docs/storage.md 第 13.5 节）：btrfs filesystem mkswapfile 自动满足
NOCOW、不压缩、预分配；@persist-swap 不做快照，swapfile 不进备份。"
  (invoke "btrfs" "filesystem" "mkswapfile"
          "--size" (number->string size-bytes)
          "--uuid" "clear"
          (string-append %btrfs-top-mount "/" subvolume-name "/swapfile")))

(define (execute-unmount-top)
  (invoke "umount" %btrfs-top-mount))

(define (mount-subvol name target options)
  (mkdir-p target)
  (let ((opts (cons (string-append "subvol=" name) options)))
    (apply invoke "mount" "-o" (string-join opts ",")
      (mapper-path) target '())))

(define (execute-mount-root name target)
  (mount-subvol name target '()))

(define (execute-mount-subvolume name target options)
  (mount-subvol name target options))

(define (execute-mount-esp target)
  (mkdir-p target)
  (invoke "mount" (by-partlabel-path %esp-partlabel) target))
