;;; astro-build.astro-vscode —— Astro 语言支持。
;;;
;;; 该扩展从 2.16.x 起只发 platform-specific 变体（无 universal）——
;;; 用 linux-x64。VsixSha256 与 Marketplace 元数据一致（交叉校验过）。
;;; 内容为纯 JS（含打包的 @astrojs/language-server），无 native 负载。

(define-module (guixcfg apps vscode extensions astro)
  #:use-module (guix packages)          ; base32
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-astro))

(define-public vscode-extension-astro
  (vscode-marketplace-extension
   "astro-build" "astro-vscode" "2.16.20"
   (base32 "1ipmzpv1l4klmd7gh6b5ads9f7wlx1q4dfpm4hb9fhv6p3cwabxg")
   #:target-platform "linux-x64"
   #:license license:expat))
