;;; QEMU application unit.

(define-module (guixcfg apps qemu definition)
  #:use-module (gnu packages virtualization)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%qemu))

(define %qemu
  (application
   (name 'qemu)
   (home-packages (list qemu))))
