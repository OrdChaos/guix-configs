;;; Privileged pinned entrypoint for the reconfigure gate transaction.
;;;
;;; Usage (repository root):
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/reconfigure-cli.scm -- HOST HOME-USER

(define (repo-root)
  (dirname (dirname (canonicalize-path (car (command-line))))))

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg system deploy)
             (guixcfg system reconfigure)
             (ice-9 match))

(define (usage)
  (format (current-error-port)
          "usage: reconfigure-cli.scm -- HOST HOME-USER~%")
  (exit 1))

(unless (zero? (getuid))
  (format (current-error-port)
          "reconfigure transaction requires root (effective UID 0)~%")
  (exit 1))

(define (run host home-user)
  (let ((root (repo-root)))
    (chdir root)
    (let ((code (reconfigure-transaction! host home-user #:root root)))
      (when (zero? code)
        (unless (zero? (apply system* (gc-cli-argv root "run" host '())))
          (format (current-error-port)
                  "WARNING: post-reconfigure generation deletion failed; run 'blue gc ~a' manually~%"
                  host)))
      (exit code))))

(match (cdr (command-line))
       (("--" host home-user) (run host home-user))
       ((host home-user) (run host home-user))
       (_ (usage)))
