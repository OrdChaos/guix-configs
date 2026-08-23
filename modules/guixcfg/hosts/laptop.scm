;;; Laptop 组装点（docs/README.md）。Host 负责组合硬件、存储 policy、
;;; boot 配置和服务。
;;;
;;; Host 是策略/选择层（inventory = facts / host = policy+selection /
;;; application = resource ownership+behavior / composition =
;;; resolution+assembly；docs/architecture/applications.md
;;; （Host-agnostic boundary））：对 application 只做 logical
;;; configuration variant selection——本模块不知道 variant 背后的
;;; 文件、目标路径或 source 位置（那些由 application 自己声明，
;;; generic (guixcfg apps selection) 解析）。application 层不读取
;;; 本模块，依赖方向保持 application ← host。
;;;
;;; 当前 laptop 尚无完整 <operating-system> 组装（roadmap：
;;; Laptop host 组装点）；本模块先落地 host 层的 home 组合 seam：
;;;   %laptop-application-configuration-selections：logical selection
;;;   %laptop-guix-home：(guix-home #:application-configuration-selections ...)
;;; VM 用默认 %guix-home（无 selection——可选配置不安装；应用侧
;;; optional include 语义保证配置仍合法，pinned niri 26.04 核实）。

(define-module (guixcfg hosts laptop)
               #:use-module ((guixcfg storage policies) #:prefix storage:)
               #:use-module (guixcfg apps selection) ; application-configuration-selection
               #:use-module (guixcfg home user)      ; guix-home
               #:export (%laptop-storage-policy
                         %laptop-application-configuration-selections
                         %laptop-guix-home))

;; 与 VM 一样，policy 本体放在 (guixcfg storage policies)，使磁盘安装
;; 阶段不必加载完整 host/boot/channel 图。
(define %laptop-storage-policy storage:%laptop-storage-policy)

;; laptop 对 application 的 logical variant selection。本模块只表达
;; "选什么"，不表达"装什么文件/装到哪里"——改变 niri 'laptop
;; variant 背后的文件或目标路径不要求修改这里。
(define %laptop-application-configuration-selections
  (list (application-configuration-selection
         (application 'niri)
         (variant 'laptop))))

;; laptop 的 Guix Home 组合：默认 home + logical selections（由
;; generic resolver 解析为配置文件贡献）。
(define %laptop-guix-home
  (guix-home
   #:application-configuration-selections
   %laptop-application-configuration-selections))
