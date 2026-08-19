;;; jq application unit：JSON 处理 CLI。

(define-module (guixcfg apps jq definition)
               #:use-module (gnu packages web) ; jq
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%jq))

(define %jq
  (application
   (name 'jq)
   (home-packages (list jq))))
