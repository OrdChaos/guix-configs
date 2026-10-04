;;; Shared kernel-module loading contract.

(use-modules ((guixcfg hosts lenovo-legion-y7000p)
              #:prefix host:)
             ((guixcfg hosts vm)
              #:prefix vm:)
             (gnu services)
             (gnu services linux)
             (gnu system)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))
(test-begin "kernel-modules")

(define (module-loader-service os)
  (find (lambda (service)
          (eq? kernel-module-loader-service-type
               (service-kind service)))
        (operating-system-services os)))

(define (loads-ntsync? os)
  (let ((service (module-loader-service os)))
    (and service
         (member "ntsync"
                 (service-value service)))))

(test-assert "laptop loads ntsync"
             (loads-ntsync? host:%lenovo-legion-y7000p-os))
(test-assert "VM loads ntsync"
             (loads-ntsync? vm:%vm-os))

(test-end "kernel-modules")
