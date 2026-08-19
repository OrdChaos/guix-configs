;;; wget application unit：HTTP 下载 CLI。

(define-module (guixcfg apps wget definition)
               #:use-module (gnu packages wget) ; wget
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%wget))

(define %wget
  (application
   (name 'wget)
   (home-packages (list wget))))
