;;; Enabled physical-printer inventory for the Laptop host.

(define-module (guixcfg system printing laptop)
  #:use-module (guixcfg system printing hp-laserjet-1020)
  #:use-module (guixcfg system printing service)
  #:export (%laptop-printing-services))

;; This is the sole composition point for CUPS.  Model modules contribute
;; queue facts and optional hardware services, never another cupsd instance.
(define %laptop-printing-services
  (printing-services (list hp-laserjet-1020-queue)
                     #:device-services
                     %hp-laserjet-1020-device-services))
