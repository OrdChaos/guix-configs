;;; 安全校验：安装器破坏性操作之前的全部检查（纯函数）。
;;; 输入是“设备事实”——由阶段 2 的 device.scm 在真实系统上探测填充；
;;; 本模块只做判断，因此可以脱离真实硬件完整测试。
;;; 对应 docs/architecture/storage.md（存储安装器安全要求）。

(define-module (guixcfg storage validate)
               #:use-module (guixcfg storage model)
               #:use-module (guix records)  ; define-record-type*
               #:use-module (srfi srfi-1)   ; filter-map
               #:export (;; 设备事实
                         <device-facts>
                         device-facts make-device-facts device-facts?
                         device-facts-path
                         device-facts-by-id
                         device-facts-partition?
                         device-facts-mounted?
                         device-facts-system-disk?
                         device-facts-live-media?
                         device-facts-size
                         ;; 校验结果
                         <check-failure>
                         check-failure make-check-failure check-failure?
                         check-failure-name check-failure-message
                         ;; 校验入口
                         validate-target validate-policy))

;;; ────────────────────────────────────────────────────────────
;;; 设备事实：对一块候选目标盘的探测结果。
;;; 阶段 2 用 lsblk/udev 填充；测试里直接手工构造。
;;; 布尔字段默认 #f：构造时只需写出“为真”的项。

(define-record-type* <device-facts>
                     device-facts make-device-facts
                     device-facts?
                     (path         device-facts-path)                          ; 如 "/dev/vda"
                     (by-id        device-facts-by-id        (default #f))     ; /dev/disk/by-id/... 或 #f
                     (partition?   device-facts-partition?   (default #f))     ; 是分区而非整块盘？
                     (mounted?     device-facts-mounted?     (default #f))     ; 自身或任一子分区已挂载？
                     (system-disk? device-facts-system-disk? (default #f))     ; 是当前正在运行的系统盘？
                     (live-media?  device-facts-live-media?  (default #f))     ; 是 LiveCD 介质？
                     (size         device-facts-size         (default 0)))     ; 容量（字节）

;;; ────────────────────────────────────────────────────────────
;;; 校验失败：哪条规则失败 + 给人看的原因。

(define-record-type* <check-failure>
                     check-failure make-check-failure
                     check-failure?
                     (name    check-failure-name)
                     (message check-failure-message))

;;; ────────────────────────────────────────────────────────────
;;; 目标设备校验（docs/architecture/storage.md的清单）。
;;; 返回失败列表；空列表表示通过。

(define (validate-target facts policy)
  "校验 FACTS 描述的设备能否作为安装目标。"
  (filter-map
   ;; 每条规则：(规则名 通过谓词 失败原因)。谓词返回 #f 即失败。
   (lambda (rule)
     (let ((name (car rule))
           (ok?  (cadr rule))
           (msg  (caddr rule)))
       (and (not (ok? facts))
            (check-failure (name name) (message msg)))))
   (list
    (list 'resolvable-by-id
          (lambda (f) (device-facts-by-id f))
          "无法解析 /dev/disk/by-id 或 by-path 符号链接，无法可靠辨认设备")
    (list 'whole-disk
          (lambda (f) (not (device-facts-partition? f)))
          "目标是分区而不是整块磁盘，拒绝操作")
    (list 'not-mounted
          (lambda (f) (not (device-facts-mounted? f)))
          "目标设备或其分区已挂载，拒绝操作")
    (list 'not-system-disk
          (lambda (f) (not (device-facts-system-disk? f)))
          "目标是当前正在运行的系统盘，拒绝操作")
    (list 'not-live-media
          (lambda (f) (not (device-facts-live-media? f)))
          "目标是 LiveCD 介质，拒绝操作")
    (list 'sufficient-size
          (lambda (f) (>= (device-facts-size f)
                          (host-storage-policy-min-disk-size policy)))
          "目标设备容量低于 host policy 下限"))))

;;; ────────────────────────────────────────────────────────────
;;; Policy 自校验：在生成任何计划之前，先保证 policy 本身没写错。

(define (validate-policy policy)
  "校验 POLICY 自身是否合法。返回失败列表；空列表表示通过。"
  (filter-map
   (lambda (rule)
     (and (not ((cadr rule) policy))
          (check-failure (name (car rule)) (message (caddr rule)))))
   (list
    (list 'esp-size-in-range
          (lambda (p) (<= %esp-min-size
                          (host-storage-policy-esp-size p)
                          %esp-max-size))
          "ESP 大小超出 2–4 GiB 策略范围")
    (list 'swapfile-positive
          (lambda (p) (> (host-storage-policy-swapfile-size p) 0))
          "swapfile 大小必须为正")
    (list 'keep-at-least-two
          (lambda (p) (>= (host-storage-policy-keep-root-generations p) 2))
          "至少保留 2 个 root generation（current + last-good）")
    (list 'disk-fits-layout
          (lambda (p) (> (host-storage-policy-min-disk-size p)
                         (+ (host-storage-policy-esp-size p)
                            (host-storage-policy-swapfile-size p)
                            (gib 10))))
          "磁盘下限装不下 ESP + swapfile + 最小系统（10 GiB 余量）"))))
