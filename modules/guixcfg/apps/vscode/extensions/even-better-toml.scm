;;; tamasfe.even-better-toml —— TOML 语言支持（纯 JS，universal）。

(define-module (guixcfg apps vscode extensions even-better-toml)
  #:use-module (guix packages)          ; base32
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-even-better-toml))

(define-public vscode-extension-even-better-toml
  (vscode-marketplace-extension
   "tamasfe" "even-better-toml" "0.21.2"
   (base32 "0208cms054yj2l8pz9jrv3ydydmb47wr4i0sw8qywpi8yimddf11")
   #:license license:expat))
