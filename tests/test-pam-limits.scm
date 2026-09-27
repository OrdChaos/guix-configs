;;; Laptop PAM resource-limit contract.

(use-modules ((guixcfg hosts lenovo-legion-y7000p) #:prefix host:)
             (guixcfg users user)
             (gnu services)
             (gnu services base)
             (gnu system)
             (gnu system pam)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))
(test-begin "pam-limits")

(define %limits-service
  (find (lambda (service)
          (eq? pam-limits-service-type (service-kind service)))
        (operating-system-services host:%lenovo-legion-y7000p-os)))
(define %nofile-limit
  (and %limits-service
       (find (lambda (entry)
               (eq? 'nofile (pam-limits-entry-item entry)))
             (service-value %limits-service))))

(test-assert "laptop configures PAM limits"
             %limits-service)
(test-equal "nofile limit applies to the primary user"
            (user-profile-name %primary-user)
            (pam-limits-entry-domain %nofile-limit))
(test-equal "nofile limit sets soft and hard values"
            'both
            (pam-limits-entry-type %nofile-limit))
(test-equal "nofile limit is 65536"
            65536
            (pam-limits-entry-value %nofile-limit))

(test-end "pam-limits")
