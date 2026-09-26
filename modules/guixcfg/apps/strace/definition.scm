;;; strace application unit.

(define-module (guixcfg apps strace definition)
  #:use-module (gnu packages linux)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%strace))

(define %strace
  (application
   (name 'strace)
   (home-packages (list strace))))
