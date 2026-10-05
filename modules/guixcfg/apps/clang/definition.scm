;;; Clang application unit.
;;;
;;; The root-level .clang-format is the global fallback for clang-format's
;;; parent-directory lookup.  A nearer project .clang-format takes priority.

(define-module (guixcfg apps clang definition)
  #:use-module (gnu packages llvm)
  #:use-module (gnu services) ;extra-special-file
  #:use-module (guix gexp) ;local-file
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%clang))

(define %clang
  (application (name 'clang)
               (home-packages (list clang-toolchain))
               (system-services (list (extra-special-file "/.clang-format"
                                                          (local-file
                                                           "clang-format"
                                                           "clang-format"))))))
