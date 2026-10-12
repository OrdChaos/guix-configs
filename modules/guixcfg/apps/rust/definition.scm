;;; Rust application unit: project-selected immutable toolchains via Guix.

(define-module (guixcfg apps rust definition)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:use-module (rust-toolchain proxy)
  #:export (%rust %rust-version %rust-nightly-version))

;; Direct proxy invocations remain reproducible across channel updates.  Project
;; rust-toolchain files retain authority for project-specific versions.
(define %rust-version "1.99.0")
(define %rust-nightly-version "nightly-2026-10-10")

(define %rust
  (application (name 'rust)
               (home-packages
                (list (rust-toolchain-proxies
                       #:default-stable %rust-version
                       #:default-nightly %rust-nightly-version)))))
