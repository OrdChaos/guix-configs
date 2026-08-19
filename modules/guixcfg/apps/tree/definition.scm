;;; tree application unit：目录树显示 CLI。

(define-module (guixcfg apps tree definition)
               #:use-module (gnu packages admin) ; tree
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%tree))

(define %tree
  (application
   (name 'tree)
   (home-packages (list tree))))
