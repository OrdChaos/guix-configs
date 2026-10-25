;;; CUPS service composition and declarative queue projection.

(define-module (guixcfg system printing service)
  #:use-module (gnu packages cups)
  #:use-module (gnu services)
  #:use-module (gnu services cups)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (guixcfg system printing model)
  #:use-module (srfi srfi-1)
  #:export (printing-services))

(define %cups-local-socket "/var/run/cups/cups.sock")

(define cups-configuration-extensions
  (@@ (gnu services cups) cups-configuration-extensions))

(define %cups-filters-for-foomatic-pdftops
  ;; The legacy PPD invokes CUPS's pdftops ABI filter, whose pinned Guix build
  ;; still executes /usr/bin/pdftops.  It also expects CUPS's filter union to
  ;; resolve both pdftops and foo2zjs-wrapper by name.
  (package/inherit cups-filters
    (name "cups-filters-foomatic-pdftops")
    (arguments
     (substitute-keyword-arguments (package-arguments cups-filters)
        ((#:configure-flags flags)
         #~(cons (string-append "--with-pdftops-path="
                                #$(this-package-input "poppler")
                                "/bin/pdftops")
                  #$flags))
        ((#:phases phases)
         #~(modify-phases #$phases
            (add-after 'wrap-filters 'add-foomatic-filter-path
              (lambda _
                (substitute*
                 (string-append #$output "/lib/cups/filter/foomatic-rip")
                 (("export PATH=\"")
                  "export PATH=\"${CUPS_SERVERBIN:+$CUPS_SERVERBIN/filter:}"))))))))))

(define %printing-cups-extensions
  (cons %cups-filters-for-foomatic-pdftops
        (delq cups-filters
              (cups-configuration-extensions (cups-configuration)))))

(define (queue-option-arguments queue)
  (append-map (lambda (option) (list "-o" option))
              (printer-queue-options queue)))

(define (queue-projection-program queues)
  "Return a program that projects QUEUES into the live CUPS daemon.
lpadmin updates the declared URI, PPD and defaults on every boot/reconfigure;
the generated printers.conf remains ephemeral machine output."
  (program-file
   "guixcfg-printer-queues"
   #~(begin
       #$@(map
           (lambda (queue)
             #~(unless
                    (zero?
                     (system* #$(file-append cups "/sbin/lpadmin")
                              "-h" #$%cups-local-socket
                              "-p" #$(printer-queue-name queue)
                             "-v" #$(printer-queue-device-uri queue)
                             "-P" #$(printer-queue-ppd queue)
                             "-E"
                             #$@(queue-option-arguments queue)))
                   (error "failed to configure CUPS queue"
                          #$(printer-queue-name queue))))
           queues)
       #t)))

(define (queue-projection-service queues)
  (let ((program (queue-projection-program queues)))
    (simple-service
     'printing-queue-projection
     shepherd-root-service-type
     (list
      (shepherd-service
       (provision '(printing-queues))
       (requirement '(cups))
       (one-shot? #t)
       (respawn? #f)
       (documentation
        "Project declarative CUPS printer queues after the CUPS daemon starts.")
       (start #~(lambda ()
                  (zero? (system* #$program))))
       (stop #~(const #f)))))))

(define* (printing-services queues #:key (device-services '())
                           (cups-files-config (files-configuration)))
  "Return CUPS, driver, queue-projection and DEVICE-SERVICES for QUEUES.
DEVICE-SERVICES contain model-specific hardware integration such as udev
firmware loaders; CUPS queue state itself stays in this module."
   (let* ((queues (validate-printer-queues queues))
          (drivers (delete-duplicates
                    (append-map printer-queue-driver-packages queues))))
      (append (list (service cups-service-type
                             (cups-configuration
                              (extensions %printing-cups-extensions)
                              (files-configuration cups-files-config)))
                    (queue-projection-service queues))
             ;; cups-service-type composes individual package extensions, so
             ;; each driver must be its own contribution rather than a list.
             (map (lambda (driver)
                    (simple-service
                     (string->symbol
                      (string-append "printing-driver-" (package-name driver)))
                      cups-service-type driver))
                   drivers)
              device-services)))
