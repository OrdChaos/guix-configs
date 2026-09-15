;;; NetworkManager connection profile persistence.
;;;
;;; Persist only GUI/user-created keyfile profiles.  NetworkManager's other
;;; mutable data under /var/lib/NetworkManager is runtime/derived state and is
;;; intentionally left on the ephemeral root.

(define-module (guixcfg system network-manager-persistence)
               #:use-module (gnu services) ; simple-service
               #:use-module (guix gexp)
               #:use-module (guix modules) ; source-module-closure
               #:use-module (guixcfg system machine-state-persistence)
               #:export (%network-manager-system-connections-directory
                         %network-manager-connections-backing-directory
                         %network-manager-connections-persistence-rule
                         network-manager-connections-ownership-activation
                         network-manager-connections-persistence-service))

(define %network-manager-system-connections-directory
  "/etc/NetworkManager/system-connections")

(define %network-manager-connections-backing-directory
  (string-append %machine-state-root
                 "/network-manager/system-connections"))

(define %network-manager-connections-persistence-rule
  (machine-state-persistence-rule
   (name 'network-manager-connections)
   (backing "network-manager/system-connections")
   (consumer %network-manager-system-connections-directory)))

(define (network-manager-connections-ownership-activation)
  "Create both sides of the connection-profile projection as root:root 0700.
The backing directory supplies the visible ownership and mode after the bind
mount.  Do not recurse: NetworkManager owns profile file modes and contents."
  (with-imported-modules (source-module-closure '((guix build utils)))
    #~(begin
       (use-modules (guix build utils))
       (let ((backing #$%network-manager-connections-backing-directory)
             (consumer #$%network-manager-system-connections-directory))
         (mkdir-p backing)
         (chown backing 0 0)
         (chmod backing #o700)
         (mkdir-p consumer)
         (chown consumer 0 0)
         (chmod consumer #o700)))))

(define (network-manager-connections-persistence-service)
  (simple-service 'network-manager-connections-persistence
                  activation-service-type
                  (network-manager-connections-ownership-activation)))
