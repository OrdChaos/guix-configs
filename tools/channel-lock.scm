;;; Channel lock resolver (tooling plane, pinned environment):
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/channel-lock.scm -- CHANNELS-FILE
;;;
;;; Reads the mutable channel declarations in CHANNELS-FILE, fetches the
;;; latest commit of every declared channel (authenticating the channels
;;; that carry an introduction) and prints the resolved channel list in
;;; channels.lock.scm format -- the same s-expression
;;; `guix describe -f channels` prints.
;;;
;;; Why not `guix time-machine -C channels.scm -- describe -f channels`:
;;; that command must first compute the derivation of the channel's Guix,
;;; which evaluates the whole upstream package module tree in an inferior.
;;; `blue update` never builds (documented contract), and upstream module
;;; breakage turns that evaluation into an unbounded deprecation-warning
;;; stream (e.g. go-github-com-containernetworking-plugins in Guix master
;;; after commit e21fa88: a deprecated alias expanded from a module that
;;; is still being loaded).  latest-channel-instances is the official
;;; resolution `guix pull' performs for fetching; it never instantiates
;;; anything, so the lock can be refreshed independently of upstream
;;; package-module health.
;;;
;;; stdout carries only the channels sexp (blue update rewrites the lock
;;; from it); progress, warnings and errors go to stderr.

(use-modules (guix channels)
             (guix openpgp) ;openpgp-format-fingerprint
             (guix store)
             (guix ui) ;load*
             (ice-9 match)
             (ice-9 pretty-print)
             (srfi srfi-1)) ;every

;; Channel files are evaluated in an isolated module exposing only these
;; bindings; mirrors %safe-channel-bindings in guix/scripts/pull.scm so a
;; lock refresh sees exactly the channel-file dialect `guix pull' and
;; `guix time-machine' accept.
(define %safe-channel-bindings
  '(((guix channels)
     channel?
     channel
     channel-branch
     channel-commit
     channel-name
     channel-location
     channel-introduction
     channel-introduction?
     make-channel-introduction
     channel-introduction-first-commit-signer
     channel-introduction-first-signed-commit
     openpgp-fingerprint
     downloaded-channels
     %default-channels
     %default-guix-channel
     guix-channel?)))

(define (usage)
  (format (current-error-port)
          "usage: channel-lock.scm -- CHANNELS-FILE~%")
  (exit 1))

(define (read-channels file)
  "Return the channels declared in FILE.  Fail closed when FILE does not
evaluate to a non-empty list of channels."
  (let ((result (load* file %safe-channel-bindings #:isolated? #t)))
    (if (and (pair? result) (list? result) (every channel? result))
        result
        (begin
         (format (current-error-port)
                 "channel-lock: '~a' did not evaluate to a list of channels~%"
                 file)
         (exit 1)))))

(define (channel->lock-sexp channel commit)
  "Return the channels.lock.scm sexp for CHANNEL resolved at COMMIT.  The
layout matches `guix describe -f channels' (see channel->code), except
that COMMIT comes from the channel instance: the instance's channel
record has no commit field."
  (let ((introduction (channel-introduction channel)))
    `(channel
      (name ',(channel-name channel))
      (url ,(channel-url channel))
      (branch ,(channel-branch channel))
      (commit ,commit)
      ,@(if introduction
            `((introduction
               (make-channel-introduction
                ,(channel-introduction-first-signed-commit introduction)
                (openpgp-fingerprint
                 ,(openpgp-format-fingerprint
                   (channel-introduction-first-commit-signer
                    introduction))))))
            '()))))

(define (main args)
  (let ((file (match args
                (("--" file) file)
                ((file) file)
                (_ (usage)))))
    (with-error-handling
     (with-store store
       (let ((instances (latest-channel-instances store
                                                  (read-channels file))))
         (pretty-print (cons 'list
                             (map (lambda (instance)
                                    (channel->lock-sexp
                                     (channel-instance-channel instance)
                                     (channel-instance-commit instance)))
                                  instances))))))))

(main (cdr (command-line)))
