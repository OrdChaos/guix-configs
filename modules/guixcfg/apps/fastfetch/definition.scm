;;; fastfetch

(define-module (guixcfg apps fastfetch definition)
               #:use-module (gnu packages admin) ; fastfetch
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%fastfetch))

(define %fastfetch
  (application
   (name 'fastfetch)
   (home-packages (list fastfetch))))
