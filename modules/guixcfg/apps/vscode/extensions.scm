;;; vscode 扩展集合声明（不可变 extension model 的唯一数据入口）。
;;;
;;; 每个条目是一个 pinned Marketplace VSIX 包（virelith
;;; (virelith packages vscode-extensions) 的 vscode-marketplace-extension），
;;; publisher/name 大小写与 Marketplace 一致，version/hash 手工 pin。
;;; 全部 universal platform（无 targetPlatform variant）。
;;;
;;; 升级某个扩展的流程：
;;;   1. 确定目标版本（Marketplace 页面或 extensionquery API）；
;;;   2. 下载 VSIX 并取 hash：
;;;        guix download "https://<publisher>.gallery.vsassets.io/_apis/\
;;;public/gallery/publisher/<publisher>/extension/<name>/<version>/\
;;;assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
;;;   3. 改这里的 version 与 hash 两行，reconfigure。
;;;
;;; 收录边界：
;;;   - 语言包 MS-CEINTL.vscode-language-pack-zh-hans 必须在此（严格
;;;     immutable 集合下它不再能经 GUI 安装）；其版本与 pinned vscode
;;;     解耦——Marketplace 的 zh-hans 语言包最新即为 1.131.x 系列，
;;;     engine ^1.131.0 兼容 vscode 1.139.x。
;;;   - huytd.nord-light 提供 settings.json 的 "Nord Light Brighter"
;;;     colorTheme，缺失会导致主题回退默认。
;;;   - rgherdt.scheme-lsp 的 server 不随扩展分发：扩展经 hasbin 在
;;;     PATH 上找 guile-lsp-server（definition.scm 的 home-packages
;;;     提供）；找不到时它会提示"自动安装"——那条路径会写
;;;     extensionPath（store 只读，必然失败），属于不支持的运行时
;;;     自写行为，不要点。
;;;   - 带 ELF/.node 的扩展：先 generic 解包试跑，失败则 package
;;;     inherit + Guix-native patch（patchelf/替换 bundled 二进制），
;;;     参考 virelith 模块头注释。

(define-module (guixcfg apps vscode extensions)
  #:use-module (guix packages)          ; base32
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (%vscode-extensions))

(define-public %vscode-extensions
  (list
   (vscode-marketplace-extension
    "tsyesika" "guile-scheme-enhanced" "0.0.2"
    (base32 "0hwk13j6n7rlyx94906bvqs2b0kw1ws81khy63kx206yn9yxi0ds")
    #:license license:asl2.0)
   (vscode-marketplace-extension
    "lxl66566" "anyformatter-vscode" "0.2.0"
    (base32 "06n3q3d1dgwqgrxjr06qgagzfw1xwad21wcc361kszh6wlgvglfb")
    #:license license:expat)
   (vscode-marketplace-extension
    "rgherdt" "scheme-lsp" "0.3.12"
    (base32 "0hr4hyq4w4p88jg3pvi8xbpiwp0dhnp98xrh2zqqc03573qhsxqh")
    #:license license:gpl3)
   (vscode-marketplace-extension
    "MS-CEINTL" "vscode-language-pack-zh-hans" "1.131.2026090407"
    (base32 "10zg2zz3235gpyd3fmnvy3pzw8il7h13x3zzva5riixh36vz55qb")
    #:license license:expat)
   (vscode-marketplace-extension
    "huytd" "nord-light" "0.1.1"
    (base32 "13zvk5l5d4n8vjkn36r62n98n0nbcpxfz2ad2z325p337vg8cqdb"))
   ;; rust-analyzer：linux-x64 variant（该扩展无 universal 变体——
   ;; 捆绑 server/rust-analyzer FHS ELF 二进制）。无需 native patch：
   ;; settings.json 的 "rust-analyzer.server.path": "rust-analyzer"
   ;; 让扩展经 PATH 使用环境内的 rust-analyzer（apps/rust 的
   ;; home-packages 提供），捆绑二进制闲置不启动。
   (vscode-marketplace-extension
    "rust-lang" "rust-analyzer" "0.4.3070"
    (base32 "1fryz4wjclyj3hmh5gwhq4sq7di4nc0pflqd27gw1i6ls4d6zi69")
    #:target-platform "linux-x64"
    #:license (list license:expat license:asl2.0))
   ;; clangd：纯 JS 前端（无捆绑二进制）；后端 clangd 经默认
   ;; "clangd.path": "clangd"（PATH 查找）由 apps/clang 的
   ;; clang-toolchain 提供。
   (vscode-marketplace-extension
    "llvm-vs-code-extensions" "vscode-clangd" "0.6.0"
    (base32 "179k9qpfg07dkalqn1gpvc9l757360nh5xmcrxvs013l58y00sl6")
    #:license license:expat)))
