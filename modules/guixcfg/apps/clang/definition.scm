;;; Clang application unit.

(define-module (guixcfg apps clang definition)
  #:use-module (gnu packages llvm)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%clang))

(define %clang
  (application
   (name 'clang)
   (home-packages (list clang-toolchain))))
