;;; @deepseek-ai/dsh-experimental-auto-review — 实验性逐调用自动审查。
;;;
;;; In-box bundle：随 DSH 安装分发，不增加 npm closure；启用后 Web 与
;;; dsh-TUI 的 /permission 都会出现 Auto review。

(define-module (guixcfg apps dsh extensions auto-review)
  #:export (dsh-extension-auto-review))

(define-public dsh-extension-auto-review
  "@deepseek-ai/dsh-experimental-auto-review")
