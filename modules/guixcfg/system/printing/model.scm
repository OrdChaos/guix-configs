;;; Declarative CUPS queue inventory.

(define-module (guixcfg system printing model)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:export (<printer-queue> printer-queue make-printer-queue printer-queue?
             printer-queue-name printer-queue-device-uri printer-queue-ppd
             printer-queue-driver-packages printer-queue-filter-packages
             printer-queue-options
             validate-printer-queues))

;; A queue describes only CUPS-facing state.  USB matching and firmware
;; lifecycle are device-specific concerns owned by the corresponding model
;; module, not by this inventory.
(define-record-type* <printer-queue>
                     printer-queue
                     make-printer-queue
  printer-queue?
  (name printer-queue-name) ;string: CUPS queue name
  (device-uri printer-queue-device-uri) ;string: CUPS backend URI
  (ppd printer-queue-ppd) ;file-like: PPD supplied to lpadmin -P
  (driver-packages printer-queue-driver-packages) ;list of package
  ;; Packages whose command-line helpers are called by the PPD filter chain.
  (filter-packages printer-queue-filter-packages (default '()))
  (options printer-queue-options (default '()))) ;list of lpadmin -o values

(define (valid-nonempty-string? value)
  (and (string? value) (not (string-null? value))))

(define (validate-printer-queue queue)
  (unless (valid-nonempty-string? (printer-queue-name queue))
    (error "printer queue name must be a non-empty string" queue))
  (unless (valid-nonempty-string? (printer-queue-device-uri queue))
    (error "printer queue device URI must be a non-empty string" queue))
  (unless (and (list? (printer-queue-driver-packages queue))
               (pair? (printer-queue-driver-packages queue)))
    (error "printer queue must declare at least one driver package" queue))
  (unless (list? (printer-queue-filter-packages queue))
    (error "printer queue filter packages must be a list" queue))
  (unless (and (list? (printer-queue-options queue))
               (every valid-nonempty-string? (printer-queue-options queue)))
    (error "printer queue options must be non-empty strings" queue)))

(define (validate-printer-queues queues)
  "Validate QUEUES and reject duplicate CUPS queue names."
  (unless (and (list? queues) (pair? queues) (every printer-queue? queues))
    (error "printing configuration requires a non-empty list of printer queues"
           queues))
  (for-each validate-printer-queue queues)
  (let ((names (map printer-queue-name queues)))
    (unless (= (length names) (length (delete-duplicates names)))
      (error "printer queue names must be unique" names)))
  queues)
