;;; lxl66566.anyformatter-vscode —— formatter 前端扩展（纯 JS）。

(define-module (guixcfg apps vscode extensions anyformatter)
  #:use-module (guix packages)          ; base32
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-anyformatter))

(define-public vscode-extension-anyformatter
  (vscode-marketplace-extension
   "lxl66566" "anyformatter-vscode" "0.2.0"
   (base32 "06n3q3d1dgwqgrxjr06qgagzfw1xwad21wcc361kszh6wlgvglfb")
   #:license license:expat))
