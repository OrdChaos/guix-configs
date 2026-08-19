;;; foot application unit：terminal（niri bind Mod+Return spawn foot）。

(define-module (guixcfg apps foot definition)
               #:use-module (gnu packages terminals) ; foot
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%foot))

(define %foot
  (application
   (name 'foot)
   (home-packages (list foot))))
