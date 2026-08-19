;;; wl-clipboard application unit：Wayland clipboard（wl-copy /
;;; wl-paste）。

(define-module (guixcfg apps wl-clipboard definition)
               #:use-module (gnu packages xdisorg) ; wl-clipboard
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%wl-clipboard))

(define %wl-clipboard
  (application
   (name 'wl-clipboard)
   (home-packages (list wl-clipboard))))
