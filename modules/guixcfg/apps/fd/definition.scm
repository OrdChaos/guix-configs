;;; fd application unit：find 替代 CLI。

(define-module (guixcfg apps fd definition)
               #:use-module (gnu packages rust-apps) ; fd
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%fd))

(define %fd
  (application
   (name 'fd)
   (home-packages (list fd))))
