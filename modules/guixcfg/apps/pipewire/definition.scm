;;; PipeWire application unit：audio 生命周期（home-pipewire-service-
;;; type——pipewire + wireplumber shepherd services + profile +
;;; alsa config；官方机制，niri 不再 spawn——docs/architecture/
;;; upstream-boundaries.md）。

(define-module (guixcfg apps pipewire definition)
               #:use-module (gnu home services sound) ; home-pipewire-service-type
               #:use-module (gnu services)            ; service
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%pipewire))

(define %pipewire
  (application
   (name 'pipewire)
   (home-services (list (service home-pipewire-service-type)))))
