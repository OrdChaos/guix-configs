;;; Blue application unit：Blue 编排工具（blueprint.scm 的运行器）
;;; 进入已部署 Guix Home profile 的日常入口。
;;;
;;; package authority：pinned bluebox channel（channels.lock.scm）——
;;; 本定义只引用 channel 导出的 blue 包，不复制 package definition、
;;; 不 git-fetch upstream、不自建版本 pin。
;;;
;;; Blue/Guile 兼容性（2026-09 根因）：bluebox 的 blue 包依赖 guile-3.0
;;; （本频道 3.0.9），而 pinned Guix 的 guix 包依赖 guile-3.0-latest
;;; （3.0.11）。Guile 字节码只向后兼容，blue(3.0.9) 无法加载 3.0.11
;;; 编译的 guix 模块。这里用 package transform 把 blue 重建为
;;; guile@3.0.11（不修改 bluebox 包本体）；bluebox 注释的 3.0.11 bug
;;; 会让 blue 的 fallback-chains 回归测试失败，故跳过其测试。同一处理
;;; 见 manifests/development.scm（bootstrap/CI/rescue 入口）。
;;;
;;; 两个消费者的语义区分（有意，不是 duplicate authority）：
;;;   %blue application       → 已部署 Guix Home generation（= 上次
;;;                             成功 reconfigure 时的 lock）→ 日常
;;;                             `blue ...` 入口
;;;   manifests/development.scm → bootstrap / CI / rescue / Blue
;;;                             self-upgrade（= 当前仓库 lock 的 Blue）

(define-module (guixcfg apps blue definition)
               #:use-module (bluebox packages blue) ; blue（pinned bluebox）
               #:use-module (guix packages)
               #:use-module (guix transformations)
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%blue))

(define blue-compatible
  ((options->transformation
    '((with-input . "guile=guile@3.0.11")
      (without-tests . "blue")))
   blue))

(define %blue
  (application
   (name 'blue)
   (home-packages (list blue-compatible))))
