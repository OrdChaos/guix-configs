;;; VS Code extension 模板（apps/vscode/extensions/ 新成员的正式入口）。
;;;
;;; 标准流程：
;;;   cp templates/vscode-extension/example.scm \
;;;      modules/guixcfg/apps/vscode/extensions/<name>.scm
;;;   1. 修改模块名 (guixcfg apps vscode extensions <name>)；
;;;   2. 修改导出名 vscode-extension-<name>；
;;;   3. 填 publisher/name（大小写与 Marketplace 一致）与 version；
;;;   4. 取 hash：
;;;        guix download "https://<publisher>.gallery.vsassets.io/_apis/\
;;;public/gallery/publisher/<publisher>/extension/<name>/<version>/\
;;;assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
;;;      （platform-specific 变体在 URL 末尾加 ?targetPlatform=<tp> 并
;;;      传 #:target-platform，见 extensions/rust-analyzer.scm）；
;;;   5. license 照扩展的 LICENSE 文件填（guix licenses 前缀 license:）；
;;;   6. 在 apps/vscode/extensions.scm 显式 import + 登记进
;;;      %vscode-extensions；
;;;   7. 构建验证（tests 里 VC6 的 id 列表同步更新）、reconfigure。
;;;
;;; 需要修补（native 二进制、启动时写 settings 等扩展自带行为）时，
;;; 用 package/inherit + modify-phases 包一层，先例：
;;; extensions/guile-scheme-enhanced.scm。

(define-module (guixcfg apps vscode extensions example)
  #:use-module (guix packages) ;base32
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-example))

(define-public vscode-extension-example
  (vscode-marketplace-extension "PUBLISHER"
                                "EXTENSION-NAME"
                                "VERSION"
                                (base32 "HASH")
                                #:license license:expat))
