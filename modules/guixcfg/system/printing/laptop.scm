;;; Enabled physical-printer inventory for the Laptop host.

(define-module (guixcfg system printing laptop)
  #:use-module (gnu services cups)
  #:use-module (guixcfg system printing dupriman)
  #:use-module (guixcfg system printing hp-laserjet-1020)
  #:use-module (guixcfg system printing service)
  #:export (%laptop-printing-services))

;; This is the sole composition point for CUPS.  Model modules contribute
;; queue facts and optional hardware services, never another cupsd instance.
(define %laptop-printing-services
  (append (printing-services (list hp-laserjet-1020-queue dupriman-queue)
                             #:device-services
                             %hp-laserjet-1020-device-services
                             #:cups-files-config (files-configuration (group
                                                                       dupriman-bridge-group-name)))
          %dupriman-printing-services))
