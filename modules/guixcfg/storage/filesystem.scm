;;; 文件系统与加密层：VFAT（ESP）、LUKS2、Btrfs。
;;; 对应 docs/architecture/storage.md（磁盘布局）（固定物理布局）。

(define-module (guixcfg storage filesystem)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage partition)  ; by-partlabel-path
               #:use-module (guixcfg utils process)      ; invoke-with-stdin
               #:use-module (guix build utils)          ; invoke（mkfs 等）
               #:export (execute-format-esp
                         execute-luks-format
                         execute-luks-open
                         execute-format-btrfs))

(define (execute-format-esp)
  "格式化 ESP 为 FAT32，使用固定卷标。"
  (invoke "mkfs.vfat" "-F" "32" "-n" %esp-filesystem-label
          (by-partlabel-path %esp-partlabel)))

(define (execute-luks-format passphrase)
  "初始化 LUKS2。PASSPHRASE 由安装器确认后经 stdin 传入（--key-file=-）；
--batch-mode 使 cryptsetup 不再交互要求输入 YES。安装器已完成设备
路径确认与密码确认（docs/operations/installation.md）。"
  (invoke-with-stdin passphrase
                     "cryptsetup" "luksFormat"
                     "--type" "luks2"
                     "--batch-mode"
                     "--key-file=-"
                     "--label" %luks-label
                     (by-partlabel-path %system-partlabel)))

(define (execute-luks-open passphrase)
  "解锁 LUKS 卷到固定 mapper 名。PASSPHRASE 复用 luksFormat 时的同一
输入（install.scm 的 apply session 提供），经 stdin 传入，
不再要求第三次密码输入。"
  (invoke-with-stdin passphrase
                     "cryptsetup" "open"
                     "--key-file=-"
                     (by-partlabel-path %system-partlabel)
                     %luks-mapper-name))

(define (execute-format-btrfs mapper-path)
  "在加密卷上格式化 Btrfs，使用固定文件系统标签。"
  (invoke "mkfs.btrfs" "-f" "-L" %btrfs-filesystem-label mapper-path))
