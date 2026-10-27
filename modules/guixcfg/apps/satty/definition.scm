;;; Satty application unit: Wayland screenshot annotation with Grim and Slurp.
;;;
;;; Satty reads ~/.config/satty/config.toml but does not write configuration,
;;; so the repository owns this declarative file through Guix Home.  Capture
;;; commands belong to Niri's key bindings; this unit supplies every binary
;;; they invoke.

(define-module (guixcfg apps satty definition)
  #:use-module (gnu home services) ;home-files-service-type
  #:use-module (gnu packages image) ;grim、slurp
  #:use-module (gnu services) ;simple-service
  #:use-module (guix gexp) ;local-file
  #:use-module (virelith packages satty) ;satty
  #:use-module (guixcfg apps model)
  #:export (%satty))

(define %satty
  (application (name 'satty)
               (home-packages (list satty grim slurp))
               (home-services (list (simple-service 'satty-config
                                                    home-files-service-type
                                                    `((".config/satty/config.toml" ,
                                                       (local-file
                                                        "config.toml"
                                                        "satty-config.toml"))))))))
