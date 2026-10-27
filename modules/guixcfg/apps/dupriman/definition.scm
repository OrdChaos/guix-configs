;;; DupriMan prompt daemon for the graphical primary-user session.

(define-module (guixcfg apps dupriman definition)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system shadow)
  #:use-module (guix gexp)
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg system printing dupriman)
  #:use-module (virelith packages dupriman)
  #:export (%dupriman))

(define %dupriman
  (application (name 'dupriman)
               (home-packages (list dupriman))
               (system-services (list (simple-service 'dupriman-bridge-group
                                                      account-service-type
                                                      (list (user-group
                                                              (name
                                                               dupriman-bridge-group-name)
                                                              (system? #t))))))
               (home-services (list (simple-service 'dupriman-prompt
                                     home-shepherd-service-type
                                     (list (shepherd-service (documentation
                                                              "Run the DupriMan manual-duplex confirmation prompt in the graphical session.")
                                                             (provision '(dupriman-prompt))
                                                             (requirement '(niri))
                                                             (respawn? #f)
                                                             (modules '((shepherd
                                                                         support)))
                                                             (start #~(make-forkexec-constructor
                                                                       (list #$
                                                                        (file-append
                                                                         dupriman
                                                                         "/bin/dupriman")
                                                                        "prompt")
                                                                       #:log-file
                                                                       (string-append
                                                                        %user-log-dir
                                                                        "/dupriman-prompt.log")))
                                                             (stop #~(make-kill-destructor)))))))))
