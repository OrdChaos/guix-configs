;;; Blue application unit：Blue 编排工具（blueprint.scm 的运行器）
;;; 进入已部署 Guix Home profile 的日常入口。
;;;
;;; package authority：pinned bluebox channel（channels.lock.scm）——
;;; 本定义只引用 channel 导出的 blue 包，不复制 package definition、
;;; 不 git-fetch upstream、不自建版本 pin。
;;;
;;; 两个消费者的语义区分（有意，不是 duplicate authority）：
;;;   %blue application       → 已部署 Guix Home generation（= 上次
;;;                             成功 reconfigure 时的 lock）→ 日常
;;;                             `blue ...` 入口
;;;   manifests/development.scm → bootstrap / CI / rescue / Blue
;;;                             self-upgrade（= 当前仓库 lock 的 Blue）

(define-module (guixcfg apps blue definition)
               #:use-module (bluebox packages blue) ; blue（pinned bluebox）
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%blue))

(define %blue
  (application
   (name 'blue)
   (home-packages (list blue))))
