;;; 设备探测：在真实系统上收集 validate.scm 需要的“设备事实”。
;;; IO 尽量压薄：所有解析逻辑都是纯函数，可以用样例 JSON 脱离硬件测试。
;;; 对应 docs/storage.md 第 31 章（安装器安全要求的输入侧）。

(define-module (guixcfg storage device)
               #:use-module (guixcfg storage model)
               #:use-module (guixcfg storage validate)
               #:use-module (guix records)
               #:use-module (ice-9 ftw)     ; scandir
               #:use-module (ice-9 popen)
               #:use-module (ice-9 rdelim)
               #:use-module (json)
               #:use-module (srfi srfi-1)
               #:export (;; 纯解析（可测试）
                         <device-node>
                         device-node device-node?
                         device-node-path device-node-type device-node-size
                         device-node-mountpoints device-node-children
                         parse-lsblk-json
                         device-node-mounted?
                         ;; IO 探测
                         probe-device
                         find-persistent-alias
                         system-disk-device
                         canonical-device
                         ;; 命令执行辅助（install.scm 的环境检查等使用）
                         command-lines
                         first-command-line))

;;; ────────────────────────────────────────────────────────────
;;; lsblk 输出的结构化表示（纯数据）。

(define-record-type* <device-node>
                     device-node make-device-node
                     device-node?
                     (path        device-node-path)
                     (type        device-node-type)                          ; "disk" / "part" / "rom" / "loop" ...
                     (size        device-node-size         (default 0))      ; 字节
                     (mountpoints device-node-mountpoints  (default '()))    ; 挂载点列表（空 = 未挂载）
                     (children    device-node-children     (default '())))   ; 子节点（分区等）

(define (device-node-mounted? node)
  "该节点自身是否已挂载。"
  (not (null? (device-node-mountpoints node))))

;;; ────────────────────────────────────────────────────────────
;;; lsblk --json 解析。
;;; Guile 的 (json)：对象解析为键是字符串的关联列表，数组解析为向量。
;;; 不同 lsblk 版本的挂载点字段不同（新版 MOUNTPOINTS 是数组，旧版 MOUNTPOINT
;;; 是单个字符串），这里统一归一化成字符串列表。

(define (jref obj key)
  "从 json->scm 产出的关联列表里按字符串键取值；兼容符号键。"
  (cond ((assoc-ref obj key) => identity)
    ((assoc-ref obj (string->symbol key)) => identity)
    (else #f)))

(define (jlist value)
  "把 JSON 数组（向量）归一化成 Scheme 列表；#f 归一化成空列表。"
  (cond ((vector? value) (vector->list value))
    ((list? value) value)
    (else '())))

(define (node-mountpoints obj)
  (let ((mps (jref obj "mountpoints"))
        (mp  (jref obj "mountpoint")))
    (filter string?
            (cond (mps (jlist mps))
              (mp  (list mp))
              (else '())))))

(define (parse-device-node obj)
  "把一个 blockdevice 对象解析成 <device-node>（递归处理 children）。"
  (device-node
   (path (jref obj "path"))
   (type (jref obj "type"))
   (size (let ((s (jref obj "size")))
           ;; -b 选项下是整数；防御性地容忍数字字符串。
           (if (string? s) (string->number s) s)))
   (mountpoints (node-mountpoints obj))
   (children (map parse-device-node (jlist (jref obj "children"))))))

(define (parse-lsblk-json json-string)
  "解析 lsblk --json 输出，返回第一个块设备的 <device-node>。"
  (let ((devices (jlist (jref (json-string->scm json-string) "blockdevices"))))
    (and (not (null? devices))
         (parse-device-node (car devices)))))

;;; ────────────────────────────────────────────────────────────
;;; 以下为 IO 部分。

(define (command-lines program . args)
  "执行命令，把 stdout 按行返回；失败返回空列表。"
  (let* ((port (apply open-pipe* (cons* OPEN_READ program args)))
         (lines (let loop ((acc '()))
                  (let ((line (read-line port 'concat)))
                    (if (eof-object? line)
                      (reverse acc)
                      (loop (cons (string-trim-right line #\newline) acc)))))))
    (close-pipe port)
    lines))

(define (first-command-line program . args)
  (let ((lines (apply command-lines program args)))
    (and (not (null? lines)) (car lines))))

(define (canonical-device path)
  "解析符号链接，得到设备的真实路径（/dev/disk/by-* 链接也会解开）。"
  (or (first-command-line "readlink" "-f" path) path))

(define (find-persistent-link path subdir)
  "在 /dev/disk/SUBDIR/ 中找指向 PATH 的符号链接，返回完整链接路径或 #f。
整盘的链接不会匹配到它的分区（分区链接解析后是分区路径）。"
  (let ((dir (string-append "/dev/disk/" subdir))
        (target (canonical-device path)))
    (and (file-exists? dir)
         (any (lambda (entry)
                (let ((link (string-append dir "/" entry)))
                  (and (string=? (canonical-device link) target)
                       link)))
              (or (scandir dir (lambda (f)
                                 (not (member f '("." "..")))))
                  '())))))

(define (find-persistent-alias path)
  "PATH 的稳定 udev 别名：优先 by-id（硬件序列号，最可靠）；
没有则退到 by-path（总线位置）。
QEMU/virtio 盘在 eudev 下没有 by-id 链接，只有 by-path。"
  (or (find-persistent-link path "by-id")
      (find-persistent-link path "by-path")))

(define (strip-subvol-suffix source)
  "findmnt 对 Btrfs 子卷根会输出 /dev/mapper/cryptroot[/@] 形式，
去掉 [...] 子卷后缀，只保留设备路径。"
  (let ((bracket (string-index source #\[)))
    (if bracket
      (string-take source bracket)
      source)))

(define (underlying-device-name dev)
  "DEV 的下层设备名：普通分区查 PKNAME；dm-crypt 等映射设备没有 PKNAME，
改查 sysfs 的 slaves/ 目录（多块下层设备时取第一块，本项目的固定布局只有一块）。"
  (let ((pkname
         (first-command-line
          "lsblk" "-dno" "PKNAME" dev)))
    (if (and pkname (not (string-null? pkname)))
      pkname
      (let ((slaves-dir
             (string-append
              "/sys/block/"
              (basename dev)
              "/slaves")))
        (and (file-exists? slaves-dir)
             (let ((entries
                    (scandir
                     slaves-dir
                     (lambda (f)
                       (not (member f '("." "..")))))))
               (and (pair? entries)
                    (car entries))))))))

(define (whole-disk-of source)
  "从任意块设备沿下层设备向上找，直到 type=disk 的整盘。
分区 → 整盘是一层；dm-crypt 映射 → 分区 → 整盘是两层。
用 seen 记录访问过的设备，遇到环路或够不到整盘的异常拓扑时返回 #f
（宁可认不出系统盘，也不死循环、也不把分区误报成整盘）。"
  (let loop ((dev source)
             (seen '()))
    (if (member dev seen)
      #f
      (let ((type (first-command-line "lsblk" "-dno" "TYPE" dev)))
        (cond ((equal? type "disk")
               dev)
          (else
           (let ((underlying (underlying-device-name dev)))
             (and underlying
                  (loop (string-append "/dev/" underlying)
                        (cons dev seen))))))))))

(define (system-disk-device)
  "当前根文件系统所在的整块磁盘，或 #f（例如 LiveCD 的 overlay 根）。"
  (let ((source (first-command-line "findmnt" "-no" "SOURCE" "/")))
    (and source
         (string-prefix? "/dev/" source)
         (whole-disk-of (canonical-device (strip-subvol-suffix source))))))

(define (live-root?)
  "当前系统是否从 LiveCD 介质运行（根是 iso9660/squashfs/overlay 等只读组合）。"
  (let ((fstype (first-command-line "findmnt" "-no" "FSTYPE" "/")))
    (and fstype (member fstype '("iso9660" "squashfs" "overlay")) #t)))

;;; ────────────────────────────────────────────────────────────
;;; 主入口：探测一块候选目标盘，填充 <device-facts>。

(define (probe-device path)
  "收集 PATH 设备的全部事实。只读操作，不修改任何状态。"
  (let* ((node (parse-lsblk-json
                (string-concatenate
                 (command-lines "lsblk" "--json" "-b"
                                "-o" "NAME,PATH,TYPE,SIZE,MOUNTPOINTS"
                                path))))
         (mounted (and node
                       (or (device-node-mounted? node)
                           (any device-node-mounted?
                                (device-node-children node)))))
         (system-disk (system-disk-device))
         (on-system-disk (and system-disk
                              (string=? (canonical-device path) system-disk))))
    (device-facts
     (path path)
     (by-id (find-persistent-alias path))
     (partition? (and node (equal? (device-node-type node) "part")))
     ;; LiveCD 的安装介质自身就是挂载着的（根或 /run 在它上面），
     ;; 因此 mounted? 检查已经能拦住它；live-media? 提供更准确的错误信息。
     (mounted? mounted)
     (system-disk? on-system-disk)
     (live-media? (and on-system-disk (live-root?)))
     (size (if node (device-node-size node) 0)))))
