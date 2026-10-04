;;; huytd.nord-light —— Nord 主题包；settings.json 的
;;; "Nord Light Brighter" colorTheme 由它提供，缺失会导致主题回退默认。

(define-module (guixcfg apps vscode extensions nord-light)
  #:use-module (guix packages) ;base32
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-nord-light))

(define-public vscode-extension-nord-light
  (vscode-marketplace-extension "huytd" "nord-light" "0.1.1"
                                (base32
                                 "13zvk5l5d4n8vjkn36r62n98n0nbcpxfz2ad2z325p337vg8cqdb")))
