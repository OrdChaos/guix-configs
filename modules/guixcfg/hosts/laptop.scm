;;; Laptop 最终 <operating-system> 组装点（阶段 6）。
;;; Host 负责组合硬件、存储 policy、boot 配置和服务（docs/project-definition.md 第 21 章）。

(define-module (guixcfg hosts laptop)
               #:use-module (guixcfg storage model)
               #:export (%laptop-storage-policy))

;; Laptop 存储 policy（docs/storage.md 第 20.2 节）：
;; 实机参数，首次实机安装时按实际 SSD 容量和内存大小校准。
(define %laptop-storage-policy
  (host-storage-policy
   (name 'laptop)
   (esp-size (gib 4))
   (min-disk-size (gib 200))
   (swapfile-size (gib 16))
   (keep-root-generations 5)))
