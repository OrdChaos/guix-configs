;;; Ninja application unit.

(define-module (guixcfg apps ninja definition)
  #:use-module (gnu packages build-tools)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%ninja))

(define %ninja
  (application
   (name 'ninja)
   (home-packages (list ninja))))
