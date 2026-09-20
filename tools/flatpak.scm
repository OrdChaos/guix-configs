;;; Pinned execution entrypoint for the Blue Flatpak namespace.
;;;
;;; Usage (repository root):
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/flatpak.scm -- MODE ACTION [ARGS...]
;;; MODE is `run` or `dry-run`.

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg flatpak command)
             (ice-9 match))

(define (usage)
  (format (current-error-port)
          "usage: flatpak.scm -- (run|dry-run) ACTION [ARGS...]~%")
  (exit 1))

(match (cdr (command-line))
  (("run" action . rest)
   (run-flatpak-command (cons action rest) #f))
  (("dry-run" action . rest)
   (run-flatpak-command (cons action rest) #t))
  (("--" "run" action . rest)
   (run-flatpak-command (cons action rest) #f))
  (("--" "dry-run" action . rest)
   (run-flatpak-command (cons action rest) #t))
  (_ (usage)))
