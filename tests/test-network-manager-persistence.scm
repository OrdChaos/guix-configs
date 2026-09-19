;;; Laptop NetworkManager connection-profile persistence contract.

(use-modules (guixcfg hosts lenovo-legion-y7000p)
             (guixcfg hosts vm)
             (guixcfg system machine-state-persistence)
             (guixcfg system network-manager-persistence)
             (gnu services)
             (gnu services shepherd)
             (gnu system)
             (gnu system file-systems)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))
(test-begin "network-manager-persistence")

(define (mount-at os path)
  (find (lambda (fs) (string=? path (file-system-mount-point fs)))
        (operating-system-file-systems os)))

(define %consumer %network-manager-system-connections-directory)
(define %backing %network-manager-connections-backing-directory)
(define %lenovo-legion-y7000p-mount
  (mount-at %lenovo-legion-y7000p-os %consumer))

(test-assert "connection profile rule is valid"
             (valid-machine-state-persistence-rule?
              %network-manager-connections-persistence-rule))
(test-equal "consumer is NetworkManager's system keyfile directory"
            "/etc/NetworkManager/system-connections"
            (machine-state-persistence-rule-consumer
             %network-manager-connections-persistence-rule))
(test-assert "laptop binds persistent connection profiles"
              (and %lenovo-legion-y7000p-mount
                   (string=? %backing
                             (file-system-device %lenovo-legion-y7000p-mount))
                   (memq 'bind-mount
                         (file-system-flags %lenovo-legion-y7000p-mount))))
(test-assert "VM does not persist NetworkManager profiles"
             (not (mount-at %vm-os %consumer)))
(test-assert "volatile NetworkManager state is not persisted"
              (not (mount-at %lenovo-legion-y7000p-os
                             "/var/lib/NetworkManager")))

(define %ownership-source
  (object->string
   (gexp->approximate-sexp
    (network-manager-connections-ownership-activation))))

(test-assert "ownership activation covers backing and consumer"
             (and (string-contains %ownership-source %backing)
                  (string-contains %ownership-source %consumer)))
(test-assert "ownership activation enforces root ownership and mode 0700"
             (and (string-contains %ownership-source "chown backing 0 0")
                  (string-contains %ownership-source "chown consumer 0 0")
                  ;; #o700 is represented as decimal 448 in approximate gexp output.
                  (string-contains %ownership-source "chmod backing 448")
                  (string-contains %ownership-source "chmod consumer 448")))
(test-assert "ownership activation does not recursively alter profiles"
             (and (not (string-contains %ownership-source "chown-recursive"))
                  (not (string-contains %ownership-source "chmod-recursive"))))

(define %shepherd-services
  (shepherd-configuration-services
   (service-value
    (fold-services (operating-system-services %lenovo-legion-y7000p-os)
                   #:target-type shepherd-root-service-type))))

(define (service-providing provision)
  (find (lambda (service)
          (memq provision (shepherd-service-provision service)))
        %shepherd-services))

(define %network-manager (service-providing 'NetworkManager))
(define %user-processes (service-providing 'user-processes))
(define %file-systems (service-providing 'file-systems))
(define %connection-mount
  (service-providing
   'file-system-/etc/NetworkManager/system-connections))

(test-assert "ordering services are present"
             (and %network-manager %user-processes %file-systems %connection-mount))
(test-assert "NetworkManager starts after user-processes"
             (memq 'user-processes
                   (shepherd-service-requirement %network-manager)))
(test-assert "user-processes starts after file-systems"
             (memq 'file-systems
                   (shepherd-service-requirement %user-processes)))
(test-assert "file-systems target waits for the profile bind"
             (memq 'file-system-/etc/NetworkManager/system-connections
                   (shepherd-service-requirement %file-systems)))

(test-end "network-manager-persistence")
