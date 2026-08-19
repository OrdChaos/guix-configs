;;; ripgrep application unit：代码搜索 CLI。

(define-module (guixcfg apps ripgrep definition)
               #:use-module (gnu packages rust-apps) ; ripgrep
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%ripgrep))

(define %ripgrep
  (application
   (name 'ripgrep)
   (home-packages (list ripgrep))))
