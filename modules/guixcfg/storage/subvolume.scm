;;; Btrfs 子卷创建与挂载：持久子卷、安装期 root、swapfile、最终挂载树。
;;; 对应 docs/architecture/storage.md（持久子卷）；swapfile 约束见 Swap 一节。

(define-module (guixcfg storage subvolume)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage device) ; first-command-line（mount-top 幂等探测）
               #:use-module (guix build utils)
               #:use-module (ice-9 format)
               #:export (%btrfs-top-mount
                         execute-mount-top
                         execute-make-subvolume
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
集成测试覆盖（见 tests/test-commit-root.scm）；产品默认 %luks-mapper-path。"
  (or (let ((v (getenv "GUIXCFG_TEST_LUKS_MAPPER")))
        (and v (not (string-null? v)) v))
      %luks-mapper-path))

(define (execute-mount-top)
  "幂等：已挂载（resume 场景）时 no-op。探测失败（findmnt 缺失）
  时按未挂载处理（保持原行为）。"
  (mkdir-p %btrfs-top-mount)
  (let ((already (false-if-exception
                  (first-command-line "findmnt" "-no" "TARGET"
                                      %btrfs-top-mount))))
    (unless (and already (not (string-null? already)))
      (invoke "mount" "-o" "subvolid=5" (mapper-path) %btrfs-top-mount))))

(define (execute-make-subvolume name)
  (invoke "btrfs" "subvolume" "create"
          (string-append %btrfs-top-mount "/" name)))

(define (execute-make-swapfile subvolume-name size-bytes)
  "在子卷 SUBVOLUME-NAME（如 @persist-swap）里创建 swapfile
（docs/architecture/storage.md（Swap））：btrfs filesystem mkswapfile 自动满足
NOCOW、不压缩、预分配；@persist-swap 不做快照，swapfile 不进备份。"
  (invoke "btrfs" "filesystem" "mkswapfile"
          "--size" (number->string size-bytes)
          "--uuid" "clear"
          (string-append %btrfs-top-mount "/" subvolume-name "/swapfile")))

(define (execute-unmount-top)
  (invoke "umount" %btrfs-top-mount))

(define (mount-point-mounted? target)
  "TARGET 已挂载？（resume 幂等探测；findmnt 缺失/失败按未挂载处理）。"
  (let ((r (false-if-exception
            (first-command-line "findmnt" "-no" "TARGET" target))))
    (and r (not (string-null? r)))))

(define (mount-subvol name target options)
  "幂等：TARGET 已挂载时 no-op（resume 场景重复重放 mount 步骤）。"
  (mkdir-p target)
  (unless (mount-point-mounted? target)
    (let ((opts (cons (string-append "subvol=" name) options)))
      (apply invoke "mount" "-o" (string-join opts ",")
        (mapper-path) target '()))))

(define (execute-mount-root name target)
  (mount-subvol name target '()))

(define (execute-mount-subvolume name target options)
  (mount-subvol name target options))

(define (execute-mount-esp target)
  (mkdir-p target)
  (unless (mount-point-mounted? target)
    (invoke "mount" (by-partlabel-path %esp-partlabel) target)))
