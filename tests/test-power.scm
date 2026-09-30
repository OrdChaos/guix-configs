;;; Laptop power management wiring test（docs/architecture/power.md）。
;;;
;;; 覆盖：
;;;   P1  laptop TLP 使用 virelith tlp-with-pd，且机器策略字段正确
;;;       （EPP、离电关睿频、NVMe disk）；
;;;   P2  %laptop-power-services 的 tlp-pd shepherd 服务语义
;;;       （provision tlp-pd、requirement dbus-system、gdbus callback PATH）；
;;;   P3  simple-service 接线到正确的 service-type（shepherd-root /
;;;       dbus-root / polkit）；
;;;   P4  host gating：laptop OS 含 TLP + tlp-pd；VM OS 零 power；
;;;   P5  single owner：laptop 不引入 power-profiles-daemon。
;;;
;;; 纯 Scheme——不触 flatpak/网络/derivation 构建。tlp-configuration /
;;; dbus / polkit 的 accessor 未 export，经 @@ 取私有绑定（仓库既有
;;; 模式，见 test-nvidia.scm）。

(use-modules ((guixcfg hosts lenovo-legion-y7000p) #:prefix host:)
             ((guixcfg hosts vm) #:prefix vm:)
             (guixcfg system power)
             (virelith packages tlp)             ; tlp-with-pd
             (gnu services)                      ; service-kind、service-value、simple-service 等
             (gnu services dbus)                 ; dbus-root-service-type、polkit-service-type
             (gnu services pm)                   ; tlp-service-type、power-profiles-daemon-service-type
             (gnu services shepherd)             ; shepherd-service?
             (gnu system)                        ; operating-system-user-services
             (srfi srfi-1)                       ; find、any
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define tlp-configuration-tlp
  (@@ (gnu services pm) tlp-configuration-tlp))
(define tlp-configuration-cpu-energy-perf-policy-on-bat
  (@@ (gnu services pm) tlp-configuration-cpu-energy-perf-policy-on-bat))
(define tlp-configuration-cpu-boost-on-bat?
  (@@ (gnu services pm) tlp-configuration-cpu-boost-on-bat?))
(define tlp-configuration-disks-devices
  (@@ (gnu services pm) tlp-configuration-disks-devices))

(test-begin "power")

;; ── P1：TLP 机器策略 ────────────────────────────────────────
(test-assert "P1: laptop TLP uses the virelith tlp-with-pd package"
             (eq? (tlp-configuration-tlp %laptop-tlp-configuration)
                  tlp-with-pd))

(test-equal "P1: EPP on battery is balance_power"
            "balance_power"
            (tlp-configuration-cpu-energy-perf-policy-on-bat
             %laptop-tlp-configuration))

(test-equal "P1: turbo boost disabled on battery"
            #f
            (tlp-configuration-cpu-boost-on-bat? %laptop-tlp-configuration))

(test-equal "P1: TLP manages the NVMe disk (record default is sda-only)"
            '("nvme0n1" "sda")
            (tlp-configuration-disks-devices %laptop-tlp-configuration))

;; ── P2：tlp-pd shepherd 服务语义 ────────────────────────────
(define %tlp-pd-service
  (find (lambda (s) (eq? (service-type-name (service-kind s)) 'tlp-pd))
        (operating-system-user-services host:%lenovo-legion-y7000p-os)))

(test-assert "P2: laptop OS carries the tlp-pd shepherd service"
             %tlp-pd-service)

(test-assert "P2: tlp-pd starts after dbus-system and provisions tlp-pd"
             (let ((svc (car (service-value %tlp-pd-service))))
               (and (shepherd-service? svc)
                    (memq 'tlp-pd (shepherd-service-provision svc))
                    (memq 'dbus-system (shepherd-service-requirement svc)))))

(test-assert "P2: tlp-pd PATH includes glib gdbus for TLP SyncProfile callbacks"
             ;; tlp-pd runs `tlp <profile>` asynchronously.  TLP then calls
             ;; gdbus SyncProfile to update ActiveProfile; without glib/bin,
             ;; hardware changes while Noctalia keeps the stale D-Bus value.
             (let ((source (call-with-input-file
                            "modules/guixcfg/system/power.scm"
                            (lambda (port) (read-string port)))))
               (and (string-contains source "(gnu packages glib)")
                    (string-contains source "(gexp-input glib \"bin\")")
                    (string-contains source "PATH="))))

;; ── P3：simple-service 接线 ─────────────────────────────────
(define (service-extends? svc target-type)
  (any (lambda (ext)
         (eq? (service-extension-target ext) target-type))
       (service-type-extensions (service-kind svc))))

(define (service-by-name name)
  (find (lambda (s) (eq? (service-type-name (service-kind s)) name))
        %laptop-power-services))

(test-assert "P3: tlp-pd extends shepherd-root-service-type"
             (service-extends? (service-by-name 'tlp-pd)
                               shepherd-root-service-type))
(test-assert "P3: dbus policy extends dbus-root-service-type"
             (service-extends? (service-by-name 'tlp-pd-dbus-policy)
                               dbus-root-service-type))
(test-assert "P3: polkit action extends polkit-service-type"
             (service-extends? (service-by-name 'tlp-pd-polkit-action)
                               polkit-service-type))

;; ── P4：host gating ─────────────────────────────────────────
(define (has-kind? os kind)
  (any (lambda (s) (eq? (service-kind s) kind))
       (operating-system-user-services os)))

(test-assert "P4: laptop OS contains tlp-service-type"
             (has-kind? host:%lenovo-legion-y7000p-os tlp-service-type))
(test-assert "P4: laptop OS contains the tlp-pd service"
             (service-by-name 'tlp-pd))
(test-assert "P4: VM OS has no tlp-service-type"
             (not (has-kind? vm:%vm-os tlp-service-type)))

;; ── P5：single owner（不得并存 PPD）─────────────────────────
(test-assert "P5: laptop OS does not include power-profiles-daemon"
             (not (has-kind? host:%lenovo-legion-y7000p-os
                             power-profiles-daemon-service-type)))

(test-end "power")
