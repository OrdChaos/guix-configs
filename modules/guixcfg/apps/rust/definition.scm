;;; Rust application unit: project-selected immutable toolchains via Guix.

(define-module (guixcfg apps rust definition)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:use-module (rust-toolchain proxy)
  #:export (%rust %rust-version %rust-nightly-version %rust-toolchains))

;; This is the complete installed set.  Channel manifest updates make new
;; versions available, but never alter this project-level selection.
(define %rust-version "1.99.1")
(define %rust-nightly-version "nightly-2026-10-23")

(define %rust-toolchains
  (list (rust-toolchain-entry "1.99.0"
                              #:components '("rust-analyzer-preview" "rust-src"))
        (rust-toolchain-entry %rust-version
                              #:components '("rust-analyzer-preview" "rust-src"))
        (rust-toolchain-entry "nightly-2026-08-01"
                              #:components '("rust-analyzer-preview" "rust-src"))
        (rust-toolchain-entry %rust-nightly-version
                              #:components '("rust-analyzer-preview" "rust-src"))))

(define %rust
  (application (name 'rust)
                (home-packages
                 (list (rust-toolchain-proxies
                        #:toolchains %rust-toolchains
                        #:default-stable %rust-version
                        #:default-nightly %rust-nightly-version)))))
