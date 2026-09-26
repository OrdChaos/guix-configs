;;; GDB application unit.

(define-module (guixcfg apps gdb definition)
  #:use-module (gnu packages gdb)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%gdb))

(define %gdb
  (application
   (name 'gdb)
   (home-packages (list gdb))))
