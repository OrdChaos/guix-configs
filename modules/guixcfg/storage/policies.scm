;;; Host 存储 policy：只描述磁盘布局参数，不依赖完整 operating-system。
;;;
;;; 这个模块必须保持“早期安装可加载”：LiveCD 上的 disk-install 在
;;; /gnu/store 尚未切到目标盘、也尚未进入 channels.lock.scm 之前就会加载它。
;;; 因此这里不能导入 boot、services、Rosenthal/Nonguix 等 channel 模块。

(define-module (guixcfg storage policies)
               #:use-module (guixcfg storage model)
               #:export (%vm-storage-policy
                         %laptop-storage-policy
                         storage-policy-by-name))

;; QEMU 测试盘，容量小，不绑定具体 by-id（安装时必须显式传入设备）。
(define %vm-storage-policy
  (host-storage-policy
   (name 'vm)
   (esp-size (gib 2))
   (min-disk-size (gib 20))
   (swapfile-size (gib 4))
   (keep-root-generations 3)))

;; 实机参数；首次实机安装时按实际 SSD 容量和内存大小校准。
(define %laptop-storage-policy
  (host-storage-policy
   (name 'laptop)
   (esp-size (gib 4))
   (min-disk-size (gib 200))
   (swapfile-size (gib 16))
   (keep-root-generations 5)))

(define (storage-policy-by-name name)
  "返回 NAME 对应的 host storage policy。NAME 可为字符串或符号；未知时返回 #f。"
  (case (if (symbol? name) name (string->symbol name))
    ((vm) %vm-storage-policy)
    ((laptop) %laptop-storage-policy)
    (else #f)))
