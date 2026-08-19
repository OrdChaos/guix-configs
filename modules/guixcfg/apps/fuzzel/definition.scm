;;; fuzzel application unit：app launcher（niri bind Mod+D spawn
;;; fuzzel）。

(define-module (guixcfg apps fuzzel definition)
               #:use-module (gnu packages xdisorg) ; fuzzel
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%fuzzel))

(define %fuzzel
  (application
   (name 'fuzzel)
   (home-packages (list fuzzel))))
