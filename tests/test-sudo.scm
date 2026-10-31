;;; sudo host projection test.
;;;
;;; Both hosts must lower to the same declarative sudoers policy.

(use-modules (guixcfg system sudo policy)
             (guixcfg hosts vm)
             (guixcfg hosts lenovo-legion-y7000p)
             (gnu system) ;operating-system-sudoers-file
             (guix gexp) ;lower-object
             (guix monads)
             (guix store)
             (ice-9 textual-ports) ;get-string-all
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "sudo")

(define %store
  (open-connection))

;; This test only compares declarative policy text; disable grafting so
;; derivation lowering cannot build a missing package output.
(run-with-store %store (set-grafting #f))

(define (lower-text file-like)
  "lower FILE-LIKE 并读 store 内容（test-mihomo 同款模式）。"
  (call-with-input-file (run-with-store %store
                                        (lower-object file-like))
    get-string-all))

;; ── Shared host projection ──────────────────────────────────
(test-assert "both hosts lower the same sudoers policy"
             (let ((vm-s (lower-text (operating-system-sudoers-file %vm-os)))
                   (lp-s (lower-text (operating-system-sudoers-file
                                      %lenovo-legion-y7000p-os))))
               (string=? vm-s lp-s)))

(test-end "sudo")
