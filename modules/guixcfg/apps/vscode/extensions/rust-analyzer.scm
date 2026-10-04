;;; rust-lang.rust-analyzer —— Rust LSP 客户端。
;;;
;;; linux-x64 variant（该扩展无 universal 变体——捆绑
;;; server/rust-analyzer FHS ELF 二进制）。无需 native patch：
;;; settings.json 的 "rust-analyzer.server.path": "rust-analyzer"
;;; 让扩展经 PATH 使用环境内的 rust-analyzer（apps/rust 的
;;; home-packages 提供），捆绑二进制闲置不启动。

(define-module (guixcfg apps vscode extensions rust-analyzer)
  #:use-module (guix packages) ;base32
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-rust-analyzer))

(define-public vscode-extension-rust-analyzer
  (vscode-marketplace-extension "rust-lang"
                                "rust-analyzer"
                                "0.4.3070"
                                (base32
                                 "1fryz4wjclyj3hmh5gwhq4sq7di4nc0pflqd27gw1i6ls4d6zi69")
                                #:target-platform "linux-x64"
                                #:license (list license:expat license:asl2.0)))
