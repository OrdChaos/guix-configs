;;; xdg-utils application unit: shared desktop integration commands.

(define-module (guixcfg apps xdg-utils definition)
  #:use-module (gnu packages freedesktop)
  #:use-module (guixcfg apps model)
  #:export (%xdg-utils))

(define %xdg-utils
  (application
   (name 'xdg-utils)
   (home-packages (list xdg-utils))))
