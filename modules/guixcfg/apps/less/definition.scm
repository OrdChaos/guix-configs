;;; less application unit：分页器 CLI。

(define-module (guixcfg apps less definition)
               #:use-module (gnu packages less) ; less
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%less))

(define %less
  (application
   (name 'less)
   (home-packages (list less))))
