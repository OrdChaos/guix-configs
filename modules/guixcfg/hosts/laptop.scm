;;; Laptop 最终组装点（阶段 6；docs/README.md）。Host 负责组合硬件、
;;; 存储 policy、boot 配置和服务。
;;;
;;; Host 是策略层（inventory = facts / host = policy / application =
;;; application behavior / composition = assembly；docs/architecture/
;;; applications.md（Host-agnostic boundary））：经 generic
;;; extra-configuration-files 机制向应用配置目录贡献原生配置文件
;;; （本机 = niri/host.kdl，源文件 colocate 本目录）。application
;;; 层不读取本模块，依赖方向保持 application ← host。
;;;
;;; 当前 laptop 尚无完整 <operating-system> 组装（roadmap：
;;; Laptop host 组装点）；本模块先落地 host 层的 home 组合 seam：
;;;   %laptop-extra-configuration-files：host 贡献（niri/host.kdl）
;;;   %laptop-guix-home：(guix-home #:extra-configuration-files ...)
;;; VM 用默认 %guix-home（无 extra 贡献——host.kdl 不存在，niri
;;; config.kdl 的 optional include 仅警告，pinned niri 26.04 语义）。

(define-module (guixcfg hosts laptop)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg apps extra-config) ; extra-configuration-file
               #:use-module (guixcfg home user)     ; guix-home
               #:use-module (guix gexp)             ; local-file
               #:export (%laptop-storage-policy
                         %laptop-extra-configuration-files
                         %laptop-guix-home))

;; 与 VM 一样，policy 本体放在 (guixcfg storage policies)，使磁盘安装
;; 阶段不必加载完整 host/boot/channel 图。
(define %laptop-storage-policy storage:%laptop-storage-policy)

;; Host-owned niri 机器事实（原生 KDL，source-relative local-file
;; colocate 本目录：hosts/laptop/niri-host.kdl → 安装为
;; ~/.config/niri/host.kdl——"niri/host.kdl" 是 application 与 host
;; overlay 之间的稳定接缝名，path 是完整 ~/.config 相对路径，
;; application 只作 owner）。
(define %laptop-extra-configuration-files
  (list (extra-configuration-file
         (application 'niri)
         (path "niri/host.kdl")
         (source (local-file "laptop/niri-host.kdl"
                             "laptop-niri-host.kdl")))))

;; laptop 的 Guix Home 组合：默认 home + host 额外配置贡献。
(define %laptop-guix-home
  (guix-home #:extra-configuration-files %laptop-extra-configuration-files))
