;;; yzhang.markdown-all-in-one —— Markdown 事实标准增强（TOC、
;;; 快捷键、列表编辑、预览增强）。纯 JS，universal。

(define-module (guixcfg apps vscode extensions markdown-all-in-one)
  #:use-module (guix packages) ;base32
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-markdown-all-in-one))

(define-public vscode-extension-markdown-all-in-one
  (vscode-marketplace-extension "yzhang"
                                "markdown-all-in-one"
                                "3.6.3"
                                (base32
                                 "10vfxgw9l3bpihpikc3fhkj6vvd73qgzv168lz1k1m4p0hamp664")
                                #:license license:expat))
