;;; Root guix 缓存 machine-state persistence 测试
;;;（modules/guixcfg/system/guix-cache.scm）。
;;;
;;; 背景：blue reconfigure 以 root 跑 guix time-machine，root 侧
;;; channel checkout 缓存在无状态根上被丢弃，导致每次 reconfigure
;;; 全量 clone codeberg guix.git（2026-10-03 慢链路数小时）。
;;; 修复 = /persist/system/state/guix/root-cache → /root/.cache/guix
;;; 的 generic machine-state bind。
;;;
;;; 覆盖：
;;;   GC1  rule 合法：backing "guix/root-cache"、consumer
;;;        /root/.cache/guix、机制默认 exposure/lifecycle；
;;;   GC2  rule 产生 bind file-system（device 在 %machine-state-root
;;;        下、create-mount-point? #t）；
;;;   GC3  laptop OS 的 file-systems 实际含该绑定（common 接线）。

(use-modules ((guixcfg hosts lenovo-legion-y7000p)
              #:prefix host:)
             (guixcfg system guix-cache)
             (guixcfg system machine-state-persistence)
             (gnu system) ;operating-system-file-systems
             (gnu system file-systems) ;file-system-mount-point 等
             (srfi srfi-1) ;find
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "guix-cache")

;; ── GC1：持久化规则内容 ────────────────────────────────────
(test-assert "GC1: root guix cache rule persists /root/.cache/guix"
             (and (valid-machine-state-persistence-rule?
                   %guix-root-cache-persistence-rule)
                  (string=? (machine-state-persistence-rule-backing
                             %guix-root-cache-persistence-rule)
                            "guix/root-cache")
                  (string=? (machine-state-persistence-rule-consumer
                             %guix-root-cache-persistence-rule)
                            "/root/.cache/guix")))

;; ── GC2：rule 产生的 bind file-system ──────────────────────
(define guix-cache-bind-file-systems
  (machine-state-persistence-file-systems (list
                                           %guix-root-cache-persistence-rule)))

(test-assert "GC2: rule yields one bind mount from the machine-state root"
             (let ((fs (car guix-cache-bind-file-systems)))
               (and (= 1
                       (length guix-cache-bind-file-systems))
                    (string=? (file-system-mount-point fs) "/root/.cache/guix")
                    (string=? (file-system-device fs)
                              (string-append %machine-state-root
                                             "/guix/root-cache"))
                    (memq 'bind-mount
                          (file-system-flags fs))
                    (file-system-create-mount-point? fs))))

;; ── GC3：laptop OS file-systems 实际包含该绑定 ─────────────
(test-assert "GC3: laptop OS mounts /root/.cache/guix from machine state"
             (find (lambda (fs)
                     (string=? (file-system-mount-point fs)
                               "/root/.cache/guix"))
                   (operating-system-file-systems
                    host:%lenovo-legion-y7000p-os)))

(test-end "guix-cache")
