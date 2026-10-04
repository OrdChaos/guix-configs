;;; MS-CEINTL.vscode-language-pack-zh-hans —— 简体中文语言包。
;;;
;;; 严格不可变集合下语言包必须声明式提供（GUI 安装不可用）。
;;; 其版本与 pinned vscode 解耦——Marketplace 的 zh-hans 语言包最新
;;; 即为 1.131.x 系列，engine ^1.131.0 兼容 vscode 1.139.x；升级
;;; vscode 大版本时回头核对这里。

(define-module (guixcfg apps vscode extensions language-pack-zh-hans)
  #:use-module (guix packages) ;base32
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-language-pack-zh-hans))

(define-public vscode-extension-language-pack-zh-hans
  (vscode-marketplace-extension "MS-CEINTL"
                                "vscode-language-pack-zh-hans"
                                "1.131.2026090407"
                                (base32
                                 "10zg2zz3235gpyd3fmnvy3pzw8il7h13x3zzva5riixh36vz55qb")
                                #:license license:expat))
