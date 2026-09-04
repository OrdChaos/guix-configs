;;; Node.js application unit：Node.js 运行时（含 npm）。
;;;
;;; node 来自 pinned guix（gnu packages node，自带 npm）。

(define-module (guixcfg apps nodejs definition)
               #:use-module (gnu packages node)      ; node（含 npm）
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%nodejs))

(define %nodejs
  (application
   (name 'nodejs)
  (home-packages (list node))))
