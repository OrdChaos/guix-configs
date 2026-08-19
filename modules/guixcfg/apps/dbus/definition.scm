;;; D-Bus application unit：user session D-Bus 的唯一 owner
;;; （home-dbus-service-type，Home Shepherd `dbus` 服务；官方机制，
;;; 不再有 custom dbus-run-session——docs/architecture/
;;; upstream-boundaries.md）。

(define-module (guixcfg apps dbus definition)
               #:use-module (gnu home services desktop) ; home-dbus-service-type
               #:use-module (gnu services)              ; service
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%dbus))

(define %dbus
  (application
   (name 'dbus)
   (home-services (list (service home-dbus-service-type)))))
