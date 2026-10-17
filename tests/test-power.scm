;;; Laptop power management wiring test（docs/architecture/power.md）。
;;;
;;; 覆盖：
;;;   P1  %laptop-power-services 的 tlp-pd shepherd 服务语义
;;;       （provision tlp-pd、requirement dbus-system）；
;;;   P2  simple-service 接线到正确的 service-type（shepherd-root /
;;;       dbus-root / polkit）；
;;;   P3  host gating：laptop OS 含 TLP + tlp-pd；VM OS 零 power；
;;;   P4  single owner：laptop 不引入 power-profiles-daemon；
;;;   P5  fn+q（platform-profile）→ tlp-pd SyncProfile 同步适配器。
;;;
;;; 纯 Scheme——不触 flatpak/网络/derivation 构建。

(use-modules ((guixcfg hosts lenovo-legion-y7000p)
              #:prefix host:)
             ((guixcfg hosts vm)
              #:prefix vm:)
             (guixcfg system power)
             (gnu services) ;service-kind、service-value、simple-service 等
             (gnu services dbus) ;dbus-root-service-type、polkit-service-type
             (gnu services pm) ;tlp-service-type、power-profiles-daemon-service-type
             (gnu services shepherd) ;shepherd-service?
             (gnu system) ;operating-system-user-services
             (srfi srfi-1) ;find、any
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "power")

;; ── P1：tlp-pd shepherd 服务语义 ────────────────────────────
(define %tlp-pd-service
  (find (lambda (s)
          (eq? (service-type-name (service-kind s))
               'tlp-pd))
        (operating-system-user-services host:%lenovo-legion-y7000p-os)))

(test-assert "P1: laptop OS carries the tlp-pd shepherd service"
             %tlp-pd-service)

(test-assert "P1: tlp-pd starts after dbus-system and provisions tlp-pd"
             (let ((svc (car (service-value %tlp-pd-service))))
               (and (shepherd-service? svc)
                    (memq 'tlp-pd
                          (shepherd-service-provision svc))
                    (memq 'dbus-system
                          (shepherd-service-requirement svc)))))

;; ── P2：simple-service 接线 ─────────────────────────────────
(define (service-extends? svc target-type)
  (any (lambda (ext)
         (eq? (service-extension-target ext) target-type))
       (service-type-extensions (service-kind svc))))

(define (service-by-name name)
  (find (lambda (s)
          (eq? (service-type-name (service-kind s)) name))
        %laptop-power-services))

(test-assert "P2: tlp-pd extends shepherd-root-service-type"
             (service-extends? (service-by-name 'tlp-pd)
                               shepherd-root-service-type))
(test-assert "P2: dbus policy extends dbus-root-service-type"
             (service-extends? (service-by-name 'tlp-pd-dbus-policy)
                               dbus-root-service-type))
(test-assert "P2: polkit action extends polkit-service-type"
             (service-extends? (service-by-name 'tlp-pd-polkit-action)
                               polkit-service-type))

;; ── P3：host gating ─────────────────────────────────────────
(define (has-kind? os kind)
  (any (lambda (s)
         (eq? (service-kind s) kind))
       (operating-system-user-services os)))

(test-assert "P3: laptop OS contains tlp-service-type"
             (has-kind? host:%lenovo-legion-y7000p-os tlp-service-type))
(test-assert "P3: laptop OS contains the tlp-pd service"
             (service-by-name 'tlp-pd))
(test-assert "P3: VM OS has no tlp-service-type"
             (not (has-kind? vm:%vm-os tlp-service-type)))

;; ── P4：single owner（不得并存 PPD）─────────────────────────
(test-assert "P4: laptop OS does not include power-profiles-daemon"
             (not (has-kind? host:%lenovo-legion-y7000p-os
                             power-profiles-daemon-service-type)))

;; ── P5：fn+q（platform-profile）→ tlp-pd 同步适配器 ──────────
(test-assert "P5: laptop OS installs the platform-profile sync udev rule"
             (find (lambda (s)
                     (eq? (service-type-name (service-kind s))
                          'power-profile-sync-udev-rules))
                   (operating-system-user-services
                    host:%lenovo-legion-y7000p-os)))

(test-assert "P5: VM OS has no platform-profile sync rule (laptop-only)"
             (not (find (lambda (s)
                          (eq? (service-type-name (service-kind s))
                               'power-profile-sync-udev-rules))
                        (operating-system-user-services vm:%vm-os))))

(test-end "power")
