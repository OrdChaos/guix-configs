;;; HP LaserJet 1020: CUPS queue plus USB firmware lifecycle.

(define-module (guixcfg system printing hp-laserjet-1020)
  #:use-module (gnu packages base)
  #:use-module (gnu packages cups)
  #:use-module (gnu services base)
  #:use-module (guix gexp)
  #:use-module (guixcfg system printing model)
  #:use-module (virelith packages hp-printers)
  #:export (hp-laserjet-1020-queue hp-laserjet-1020-firmware-loader
             %hp-laserjet-1020-device-services))

(define %hp-laserjet-1020-device-uri "usb://HP/LaserJet%201020")

(define hp-laserjet-1020-queue
  (printer-queue
   (name "hp-laserjet-1020")
    (device-uri %hp-laserjet-1020-device-uri)
    (ppd (file-append foo2zjs "/share/cups/model/HP-LaserJet_1020.ppd.gz"))
    (driver-packages (list foo2zjs))
    ;; lpadmin's -o NAME-default=VALUE makes the server-side queue default
   ;; explicit rather than inheriting the PPD's US Letter default.
   (options '("media-default=A4"))))

;; The printer loses firmware whenever power is removed.  CUPS's USB backend
;; can upload it directly without requiring cupsd to be running yet.
(define hp-laserjet-1020-firmware-loader
  (program-file
   "hp-laserjet-1020-firmware-loader"
   #~(begin
       (unless (zero? (system* #$(file-append coreutils "/bin/sleep") "3"))
         (error "HP LaserJet 1020: USB settle delay failed"))
       (setenv "DEVICE_URI" #$%hp-laserjet-1020-device-uri)
       (unless
           (zero?
            (system* #$(file-append cups "/lib/cups/backend/usb")
                     "1" "1" "1" "1" ""
                     #$(file-append hp-laserjet-1020-firmware
                                    "/share/hp-laserjet-1020/firmware/"
                                    "sihp1020.dl")))
         (error "HP LaserJet 1020: firmware upload failed"))
       #t)))

(define %hp-laserjet-1020-firmware-udev-rule
  (file->udev-rule
   "80-hp-laserjet-1020-firmware.rules"
   (mixed-text-file
    "80-hp-laserjet-1020-firmware.rules"
    "# HP LaserJet 1020 (03f0:2b17) must receive firmware after each power-on.\n"
    "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"03f0\", "
    "ATTR{idProduct}==\"2b17\", RUN+=\""
    hp-laserjet-1020-firmware-loader
    "\"\n")))

(define %hp-laserjet-1020-firmware-service
  (udev-rules-service 'hp-laserjet-1020-firmware
                      %hp-laserjet-1020-firmware-udev-rule))

(define %hp-laserjet-1020-device-services
  (list %hp-laserjet-1020-firmware-service))
