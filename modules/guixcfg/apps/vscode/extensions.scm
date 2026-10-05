;;; vscode 扩展集合声明（不可变 extension model 的唯一数据入口）。
;;;
;;; 每个扩展是 extensions/ 子目录下的一个单文件模块，导出一个
;;; vscode-extension-<name> 包（virelith (virelith packages
;;; vscode-extensions) 的 vscode-marketplace-extension 或其
;;; package/inherit 修补变体），publisher/name 大小写与 Marketplace
;;; 一致，version/hash 手工 pin。本模块显式聚合成
;;; %vscode-extensions（与 registry 规则一致：成员在列表里显式
;;; 登记，不自动扫描目录）。
;;;
;;; 新增扩展的流程：
;;;   1. 在 extensions/ 下建单文件模块（见现有成员的注释风格）；
;;;   2. 确定目标版本（Marketplace 页面或 extensionquery API）；
;;;   3. 下载 VSIX 并取 hash：
;;;        guix download "https://<publisher>.gallery.vsassets.io/_apis/\
;;;public/gallery/publisher/<publisher>/extension/<name>/<version>/\
;;;assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
;;;      （platform-specific 变体在 URL 末尾加 ?targetPlatform=<tp>，
;;;      并给包传 #:target-platform——见 extensions/rust-analyzer.scm）
;;;   4. 在本列表登记。
;;;
;;; 升级某个扩展 = 改它自己文件里的 version 与 hash 两行，reconfigure。
;;;
;;; 带 ELF/.node 的扩展：先 generic 解包试跑，失败则 package
;;; inherit + Guix-native patch（patchelf/替换 bundled 二进制），
;;; 先例见 extensions/guile-scheme-enhanced.scm（非 native 的
;;; 行为修补）与 git 历史（f6ba178 前 rust-analyzer 的二进制替换）。

(define-module (guixcfg apps vscode extensions)
  #:use-module (guixcfg apps vscode extensions anyformatter)
  #:use-module (guixcfg apps vscode extensions astro)
  #:use-module (guixcfg apps vscode extensions clangd)
  #:use-module (guixcfg apps vscode extensions even-better-toml)
  #:use-module (guixcfg apps vscode extensions guile-scheme-enhanced)
  #:use-module (guixcfg apps vscode extensions language-pack-zh-hans)
  #:use-module (guixcfg apps vscode extensions markdown-all-in-one)
  #:use-module (guixcfg apps vscode extensions nord-light)
  #:use-module (guixcfg apps vscode extensions rust-analyzer)
  #:export (%vscode-extensions))

(define-public %vscode-extensions
  (list vscode-extension-guile-scheme-enhanced
        vscode-extension-anyformatter
        vscode-extension-language-pack-zh-hans
        vscode-extension-nord-light
        vscode-extension-rust-analyzer
        vscode-extension-clangd
        vscode-extension-astro
        vscode-extension-even-better-toml
        vscode-extension-markdown-all-in-one))
