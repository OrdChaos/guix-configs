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
  #:use-module (gnu packages rust)      ; rust-analyzer
  #:use-module (guix gexp)              ; #~ #$
  #:use-module (guix packages)          ; base32
  #:use-module (guix utils)             ; substitute-keyword-arguments
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (%vscode-extensions))

;; Native extension 示例（也是本机制的唯一 native PoC）：
;; rust-lang.rust-analyzer 的 linux-x64 VSIX 捆绑
;; extension/server/rust-analyzer（FHS ELF，/lib64/ld-linux 解释器，
;;; generic 解包后无法运行）。修复沿用 nixpkgs 对该扩展的处理思路
;; （不试图 patch 41MB 的捆绑二进制，而是用 Guix 原生包替换）：
;; 解包后将捆绑 server 替换为 rust-analyzer 包的 store 路径符号链接。
;; 注意 settings.json 现有 "rust-analyzer.server.path": "rust-analyzer"
;; （PATH 查找）优先于捆绑 server——此 override 是机制证明与兜底，
;; 两条路径互不争抢。
(define-public vscode-extension-rust-analyzer
  (let ((base (vscode-marketplace-extension
               "rust-lang" "rust-analyzer" "0.4.3070"
               (base32 "1fryz4wjclyj3hmh5gwhq4sq7di4nc0pflqd27gw1i6ls4d6zi69")
               #:target-platform "linux-x64"
               #:license (list license:expat license:asl2.0))))
    (package
      (inherit base)
      (inputs (list rust-analyzer))
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:phases phases)
          #~(modify-phases #$phases
              (add-after 'unpack 'replace-bundled-server
                (lambda* (#:key inputs #:allow-other-keys)
                  ;; 已在 unpack 阶段 chdir 进 extension/。
                  (let ((server "server/rust-analyzer"))
                    (delete-file server)
                    (symlink (search-input-file inputs "/bin/rust-analyzer")
                             server)))))))))))

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
   vscode-extension-rust-analyzer))
