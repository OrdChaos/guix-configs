;;; CUPS service composition and declarative queue projection.

(define-module (guixcfg system printing service)
  #:use-module (gnu packages cups)
  #:use-module (gnu services)
  #:use-module (gnu services cups)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guixcfg system printing model)
   #:use-module (srfi srfi-1)
   #:export (printing-services))

(define cups-configuration-policies
  (@@ (gnu services cups) cups-configuration-policies))

(define policy-configuration-name
  (@@ (gnu services cups) policy-configuration-name))

(define policy-configuration-access-controls
  (@@ (gnu services cups) policy-configuration-access-controls))

(define operation-access-control-operations
  (@@ (gnu services cups) operation-access-control-operations))

(define operation-access-control-access-controls
  (@@ (gnu services cups) operation-access-control-access-controls))

(define (queue-option-arguments queue)
  (append-map (lambda (option) (list "-o" option))
              (printer-queue-options queue)))

(define (cups-printer-administration? access-control)
  (memq 'CUPS-Add-Printer
        (operation-access-control-operations access-control)))

(define %printing-cups-configuration
  ;; CUPS's default policy requires Basic authentication for lpadmin even on
  ;; its local Unix socket.  Root intentionally has no password on this
  ;; system, so allow an already-local connection to administer queues while
  ;; retaining authentication for any non-local connection.
  (let ((config (cups-configuration)))
    (cups-configuration
     (inherit config)
     (policies
      (map (lambda (policy)
             (if (string=? (policy-configuration-name policy) "default")
                 (policy-configuration
                  (inherit policy)
                  (access-controls
                   (map (lambda (access-control)
                          (if (cups-printer-administration? access-control)
                              (operation-access-control
                               (inherit access-control)
                               (access-controls
                                (append (operation-access-control-access-controls
                                         access-control)
                                        '("Satisfy any"))))
                              access-control))
                        (policy-configuration-access-controls policy))))
                 policy))
           (cups-configuration-policies config))))))

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

(define* (printing-services queues #:key (device-services '()))
  "Return CUPS, driver, queue-projection and DEVICE-SERVICES for QUEUES.
DEVICE-SERVICES contain model-specific hardware integration such as udev
firmware loaders; CUPS queue state itself stays in this module."
  (let* ((queues (validate-printer-queues queues))
         (drivers (delete-duplicates
                   (append-map printer-queue-driver-packages queues))))
     (append (list (service cups-service-type %printing-cups-configuration)
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
