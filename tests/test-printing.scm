;;; Laptop HP LaserJet 1020 printing composition test.
;;;
;;; Covers the declarative queue facts and host gating.  Firmware transfer and
;;; print output require the physical USB printer and are documented separately.

(use-modules ((guixcfg hosts lenovo-legion-y7000p)
              #:prefix host:)
             ((guixcfg hosts vm)
              #:prefix vm:)
             (guixcfg system printing hp-laserjet-1020)
             (guixcfg system printing laptop)
             (guixcfg system printing model)
             (gnu packages cups)
              (gnu services)
              (gnu services cups)
              (gnu system)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define cups-local-socket
  (@@ (guixcfg system printing service) %cups-local-socket))

(define (service-by-kind-name os name)
  (find (lambda (service)
          (eq? (service-type-name (service-kind service)) name))
        (operating-system-user-services os)))

(test-begin "printing")

(test-equal "P1: HP queue has the expected CUPS name"
  "hp-laserjet-1020"
  (printer-queue-name hp-laserjet-1020-queue))

(test-equal "P1: HP queue uses the expected USB URI"
  "usb://HP/LaserJet%201020"
  (printer-queue-device-uri hp-laserjet-1020-queue))

(test-assert "P1: HP queue installs the foo2zjs PPD"
  (and (eq? (file-append-base (printer-queue-ppd hp-laserjet-1020-queue))
            foo2zjs)
       (equal? (file-append-suffix (printer-queue-ppd hp-laserjet-1020-queue))
               '("/share/cups/model/HP-LaserJet_1020.ppd.gz"))))

(test-equal "P1: HP queue defaults to A4"
  '("media-default=A4")
  (printer-queue-options hp-laserjet-1020-queue))

(test-assert "P2: firmware loader is a generated program"
  (and (program-file? hp-laserjet-1020-firmware-loader)
       (string=? (program-file-name hp-laserjet-1020-firmware-loader)
                 "hp-laserjet-1020-firmware-loader")))

(test-assert "P3: Laptop OS includes CUPS"
  (find (lambda (service)
          (eq? (service-kind service) cups-service-type))
        (operating-system-user-services host:%lenovo-legion-y7000p-os)))

(test-equal "P3: Laptop inventory creates exactly one CUPS service"
  1
  (length (filter (lambda (service)
                    (eq? (service-kind service) cups-service-type))
                  %laptop-printing-services)))

(test-assert "P3: Laptop OS projects declarative printer queues"
  (service-by-kind-name host:%lenovo-legion-y7000p-os
                        'printing-queue-projection))

(test-equal "P3: queue projection uses the local CUPS socket"
  "/var/run/cups/cups.sock"
  cups-local-socket)

(test-assert "P3: Laptop OS installs the HP firmware udev rule"
  (service-by-kind-name host:%lenovo-legion-y7000p-os
                        'hp-laserjet-1020-firmware-udev-rules))

(test-assert "P4: VM OS has no CUPS service"
  (not (find (lambda (service)
               (eq? (service-kind service) cups-service-type))
             (operating-system-user-services vm:%vm-os))))

(test-assert "P4: VM OS has no printer queue projection"
  (not (service-by-kind-name vm:%vm-os 'printing-queue-projection)))

(test-assert "P4: VM OS has no HP firmware udev rule"
  (not (service-by-kind-name vm:%vm-os
                             'hp-laserjet-1020-firmware-udev-rules)))

(test-end "printing")
