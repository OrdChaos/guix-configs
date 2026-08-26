;;; starship 终端美化

(define-module (guixcfg apps starship definition)
               #:use-module (gnu packages shellutils) ; starship
               #:use-module (gnu home services)
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%starship))

(define %starship
  (application
   (name 'starship)
   (home-packages (list starship))
   (home-services
    (list (simple-service 'starship-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("starship.toml" ,(local-file "starship.toml" "starship-config.toml"))))))))
