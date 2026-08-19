;;; mako application unit：notification daemon（niri config
;;; spawn-at-startup "mako"；graphical-only lifecycle owner = niri
;;; session）。

(define-module (guixcfg apps mako definition)
               #:use-module (gnu packages window-management) ; mako
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%mako))

(define %mako
  (application
   (name 'mako)
   (home-packages (list mako))))
