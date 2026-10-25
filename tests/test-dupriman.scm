;;; DupriMan CUPS/Home integration tests.

(use-modules (gnu home services shepherd)
             (gnu services)
             (gnu services shepherd)
             (gnu system accounts)
             (guix packages)
             (guixcfg apps dupriman definition)
             (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg system printing dupriman)
             (guixcfg users user)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "dupriman")

(define (app-by-name name)
  (find (lambda (app) (eq? name (application-name app))) %applications))

(define (app-contributions app target-type)
  (append-map service-value
              (filter (lambda (service)
                        (any (lambda (extension)
                               (eq? target-type
                                    (service-extension-target
                                     extension)))
                             (service-type-extensions (service-kind service))))
                      (application-home-services app))))

(define %dupriman-app (app-by-name 'dupriman))

(test-assert "D1: DupriMan is explicitly enabled"
  %dupriman-app)

(test-assert "D2: Home profile includes the prompt binary"
  (any (lambda (package) (string=? "dupriman" (package-name package)))
       (application-home-packages %dupriman-app)))

(define %dupriman-prompt-service
  (find (lambda (service)
          (eq? 'dupriman-prompt
               (shepherd-service-canonical-name service)))
        (app-contributions %dupriman-app home-shepherd-service-type)))

(test-assert "D3: prompt is supervised after the graphical session starts"
  (let ((service %dupriman-prompt-service))
    (and service
         (member 'niri (shepherd-service-requirement service))
         (not (shepherd-service-respawn? service)))))

(test-assert "D4: bridge group is a system account contribution"
  (let ((groups
         (append-map service-value
                     (application-system-services %dupriman-app))))
    (any (lambda (group)
           (and (user-group? group)
                (string=? dupriman-bridge-group-name
                          (user-group-name group))))
         groups)))

(test-assert "D5: primary user belongs to the private bridge group"
  (member dupriman-bridge-group-name
          (user-account-supplementary-groups (primary-user-account))))

(test-end "dupriman")
