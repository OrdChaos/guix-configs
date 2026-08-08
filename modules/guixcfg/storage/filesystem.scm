;;; 文件系统与加密层：VFAT（ESP）、LUKS2、Btrfs。
;;; 对应 docs/storage.md 第 11 章（固定物理布局）。

(define-module (guixcfg storage filesystem)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage partition)  ; by-partlabel-path
               #:use-module (guix build utils)
               #:export (execute-format-esp
                         execute-luks-format
                         execute-luks-open
                         execute-format-btrfs))

(define (execute-format-esp)
  "格式化 ESP 为 FAT32，使用固定卷标。"
  (invoke "mkfs.vfat" "-F" "32" "-n" %esp-filesystem-label
          (by-partlabel-path %esp-partlabel)))

(define (execute-luks-format)
  "初始化 LUKS2。交互输入并确认密码；不使用 --batch-mode，
因为这是安装期的显式人工步骤（恢复密钥在阶段 5/8 另行登记）。"
  (format #t "  >>> 接下来会要求你【设置】LUKS 密码（输入两次）。~%")
  (force-output)
  (invoke "cryptsetup" "luksFormat"
          "--type" "luks2"
          "--label" %luks-label
          (by-partlabel-path %system-partlabel)))

(define (execute-luks-open)
  "解锁 LUKS 卷到固定 mapper 名。"
  (format #t "  >>> 请输入【刚才设置】的 LUKS 密码以解锁。~%")
  (force-output)
  (invoke "cryptsetup" "open"
          (by-partlabel-path %system-partlabel)
          %luks-mapper-name))

(define (execute-format-btrfs mapper-path)
  "在加密卷上格式化 Btrfs，使用固定文件系统标签。"
  (invoke "mkfs.btrfs" "-f" "-L" %btrfs-filesystem-label mapper-path))
