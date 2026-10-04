;;; Rust application unit: project-selected immutable toolchains via Guix.

(define-module (guixcfg apps rust definition)
  #:use-module (gnu packages rust)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:use-module (rust-toolchain proxy)
  #:export (%rust))

(define %rust
  (application (name 'rust)
               (home-packages (list %rust-toolchain-proxies rust-analyzer))))
