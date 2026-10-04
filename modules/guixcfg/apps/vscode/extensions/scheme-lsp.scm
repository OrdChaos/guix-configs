;;; rgherdt.scheme-lsp —— Scheme LSP 客户端。
;;;
;;; server 不随扩展分发：扩展经 hasbin 在 PATH 上找 guile-lsp-server
;;; （apps/vscode definition.scm 的 home-packages 提供）。找不到时它
;;; 会提示"自动安装"——那条路径会写 extensionPath（store 只读，必然
;;; 失败），属于不支持的运行时自写行为，不要点。

(define-module (guixcfg apps vscode extensions scheme-lsp)
  #:use-module (guix packages)          ; base32
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-scheme-lsp))

(define-public vscode-extension-scheme-lsp
  (vscode-marketplace-extension
   "rgherdt" "scheme-lsp" "0.3.12"
   (base32 "0hr4hyq4w4p88jg3pvi8xbpiwp0dhnp98xrh2zqqc03573qhsxqh")
   #:license license:gpl3))
