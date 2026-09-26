;;; CMake application unit.

(define-module (guixcfg apps cmake definition)
  #:use-module (gnu packages cmake)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%cmake))

(define %cmake
  (application
   (name 'cmake)
   (home-packages (list cmake))))
