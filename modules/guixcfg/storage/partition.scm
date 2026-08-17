;;; 分区操作：wipe、一次性 GPT 分区、等待 udev。
;;; 每个函数对应 plan.scm 中的一个步骤 id，由 install.scm 分派调用。
;;; 分区工具用 sgdisk（gptfdisk）：一条命令完成建表 + 两个分区 + 类型码 +
;;; 命名，参数语义明确，避免 parted mkpart 的参数位置问题。
;;; 对应 docs/operations/installation.md、docs/architecture/storage.md（磁盘布局）。

(define-module (guixcfg storage partition)
               #:use-module (guixcfg storage model)
               #:use-module (guix build utils)  ; invoke（失败即抛异常，配合 install.scm 的失败即停）
               #:use-module (ice-9 format)
               #:use-module (srfi srfi-1)       ; every
               #:export (execute-wipe
                         execute-partition
                         execute-wait-udev
                         by-partlabel-path))

(define (by-partlabel-path label)
  "PARTLABEL 对应的设备节点。"
  (string-append "/dev/disk/by-partlabel/" label))

(define (execute-wipe device)
  "清除磁盘上的旧分区表和签名（sgdisk --zap-all 同时清掉 GPT 主备两头和 PMBR）。"
  (invoke "sgdisk" "--zap-all" device))

(define (execute-partition device esp-size-bytes)
  "一次性创建 GPT + ESP + 加密系统分区。
ESP：1 号分区，大小来自 host policy（2–4 GiB），类型 EF00；
系统分区：2 号分区，占用剩余全部空间，类型 8309（Linux LUKS）。"
  (let ((esp-mib (quotient esp-size-bytes (* 1024 1024))))
    (invoke "sgdisk" "--clear"
            (format #f "--new=1:0:+~aMiB" esp-mib)
            (format #f "--typecode=1:~a" %esp-gpt-typecode)
            (format #f "--change-name=1:~a" %esp-partlabel)
            "--new=2:0:0"
            (format #f "--typecode=2:~a" %system-gpt-typecode)
            (format #f "--change-name=2:~a" %system-partlabel)
            device)))

(define (execute-wait-udev device)
  "等待 udev 为 /by-partlabel/ 节点就位（docs/architecture/storage.md）。"
  (invoke "udevadm" "settle" "--timeout=15")
  (let ((deadline (+ (current-time) 15))
        (targets (map by-partlabel-path
                      (list %esp-partlabel %system-partlabel))))
    (let loop ()
      (unless (every file-exists? targets)
        (when (> (current-time) deadline)
          (error "timed out waiting for partition node" targets))
        (usleep 200000)
        (loop)))))
