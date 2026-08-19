;;; curl application unit：HTTP 传输 CLI。

(define-module (guixcfg apps curl definition)
               #:use-module (gnu packages curl) ; curl
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%curl))

(define %curl
  (application
   (name 'curl)
   (home-packages (list curl))))
