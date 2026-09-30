;;; Laptop Bluetooth wiring test（docs/architecture/bluetooth.md）。
;;;
;;; 覆盖：
;;;   B1  laptop OS 含官方 bluetooth-service-type，且 AutoEnable=false
;;;       （默认关闭，由用户按需开启）；
;;;   B2  host gating：VM OS 无 bluetooth-service-type（零 BlueZ closure）；
;;;   B3  pairing-state 规则：/var/lib/bluetooth ← machine-state backing
;;;       "bluetooth"，rule 合法；
;;;   B4  rule 产生 bind file-system（device 在 %machine-state-root 下、
;;;       create-mount-point? #t）；
;;;   B5  laptop OS 的 file-systems 实际含 /var/lib/bluetooth 绑定。
;;;
;;; kernel driver/firmware（btusb/btintel + linux-firmware ibt-*）属内核
;;; 平台层，不在本测试范围（driver 是否存在由内核 config/firmware 决定）。

(use-modules ((guixcfg hosts lenovo-legion-y7000p) #:prefix host:)
             ((guixcfg hosts vm) #:prefix vm:)
             (guixcfg system bluetooth)
             (guixcfg system machine-state-persistence)
             (gnu services)                  ; service-kind、service-value
             (gnu services desktop)          ; bluetooth-service-type
             (gnu system)                    ; operating-system-file-systems
             (gnu system file-systems)       ; file-system-mount-point 等
             (srfi srfi-1)                   ; find、any
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define bluetooth-configuration-auto-enable?
  (@@ (gnu services desktop) bluetooth-configuration-auto-enable?))

(define laptop-bluetooth-service
  (find (lambda (s) (eq? (service-kind s) bluetooth-service-type))
        (operating-system-user-services host:%lenovo-legion-y7000p-os)))

(test-begin "bluetooth")

;; ── B1：laptop BlueZ 服务与 AutoEnable ─────────────────────
(test-assert "B1: laptop OS includes the official bluetooth-service-type"
             laptop-bluetooth-service)

(test-assert "B1: BlueZ does not auto-enable the controller (default off)"
             (and laptop-bluetooth-service
                  (eq? (bluetooth-configuration-auto-enable?
                        (service-value laptop-bluetooth-service))
                       #f)))

;; ── B2：VM gating ──────────────────────────────────────────
(test-assert "B2: VM OS has no bluetooth-service-type (zero BlueZ closure)"
             (not (find (lambda (s) (eq? (service-kind s) bluetooth-service-type))
                        (operating-system-user-services vm:%vm-os))))

;; ── B3：pairing-state 持久化规则 ───────────────────────────
(test-assert "B3: Bluetooth state rule persists /var/lib/bluetooth"
             (and (valid-machine-state-persistence-rule?
                   %laptop-bluetooth-persistence-rule)
                  (string=? (machine-state-persistence-rule-backing
                             %laptop-bluetooth-persistence-rule)
                            "bluetooth")
                  (string=? (machine-state-persistence-rule-consumer
                             %laptop-bluetooth-persistence-rule)
                            "/var/lib/bluetooth")))

;; ── B4：rule 产生的 bind file-system ───────────────────────
(define bluetooth-bind-file-systems
  (machine-state-persistence-file-systems
   (list %laptop-bluetooth-persistence-rule)))

(test-assert "B4: rule yields one bind mount from the machine-state root"
             (let ((fs (car bluetooth-bind-file-systems)))
               (and (= 1 (length bluetooth-bind-file-systems))
                    (string=? (file-system-mount-point fs)
                              "/var/lib/bluetooth")
                    (string=? (file-system-device fs)
                              (string-append %machine-state-root "/bluetooth"))
                    (memq 'bind-mount (file-system-flags fs))
                    (file-system-create-mount-point? fs))))

;; ── B5：laptop OS file-systems 实际包含该绑定 ──────────────
(test-assert "B5: laptop OS mounts /var/lib/bluetooth from machine state"
             (find (lambda (fs)
                     (string=? (file-system-mount-point fs)
                               "/var/lib/bluetooth"))
                   (operating-system-file-systems host:%lenovo-legion-y7000p-os)))

(test-end "bluetooth")
