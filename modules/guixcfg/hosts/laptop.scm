;;; Laptop 最终 <operating-system> 组装点（阶段 6）。
;;; Host 负责组合硬件、存储 policy、boot 配置和服务（docs/project-definition.md 第 21 章）。

(define-module (guixcfg hosts laptop)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:export (%laptop-storage-policy))

;; 与 VM 一样，policy 本体放在 (guixcfg storage policies)，使磁盘安装
;; 阶段不必加载完整 host/boot/channel 图。
(define %laptop-storage-policy storage:%laptop-storage-policy)
