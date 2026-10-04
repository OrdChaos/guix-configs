;;; llvm-vs-code-extensions.vscode-clangd —— clangd 前端（纯 JS，
;;; 无捆绑二进制）；后端 clangd 经默认 "clangd.path": "clangd"
;;; （PATH 查找）由 apps/clang 的 clang-toolchain 提供。

(define-module (guixcfg apps vscode extensions clangd)
  #:use-module (guix packages)          ; base32
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-clangd))

(define-public vscode-extension-clangd
  (vscode-marketplace-extension
   "llvm-vs-code-extensions" "vscode-clangd" "0.6.0"
   (base32 "179k9qpfg07dkalqn1gpvc9l757360nh5xmcrxvs013l58y00sl6")
   #:license license:expat))
