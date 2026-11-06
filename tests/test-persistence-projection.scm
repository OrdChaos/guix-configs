;;; Generic persistence projection/set executor tests.
;;;
;;; Synthetic projections only: no host, application, user or real path is
;;; hard-coded.  The mechanism is exercised through a temporary directory whose
;;; name is derived from the test process id.

(use-modules (guix store)
             (guix derivations)
             (guix monads)
             (guix gexp)
             (gnu services)
             (gnu system file-systems)
             (guix build utils)
             (guixcfg system persistence)
             (guixcfg utils seed-once)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "persistence-projection")

(define %user-name
  (passwd:name (getpwuid (getuid))))

(define %base
  (string-append "/tmp/guixcfg-persistence-test-"
                 (number->string (getpid))))

(define (remove-tree path)
  (false-if-exception (delete-file-recursively path)))

(define (fresh-directory name)
  (let ((dir (string-append %base "/" name)))
    (remove-tree dir)
    dir))

(define* (projection #:key (name 'synthetic)
                    (root (string-append %base "/persist"))
                    (backing "state")
                    (consumer (string-append %base "/consumer"))
                    (exposure 'bind-directory)
                    (owner 'user)
                    (mode #o700)
                    (options #f)
                    (home #f)
                    (home-mode #f)
                    (seeds '()))
  (persistence-projection
    (name name)
    (root root)
    (backing backing)
    (consumer consumer)
    (exposure exposure)
    (owner owner)
    (owner-user (if (eq? owner 'user) %user-name #f))
    (mode mode)
    (options options)
    (home home)
    (home-mode home-mode)
    (seeds seeds)))

(define synthetic
  (projection))

(test-assert "valid synthetic projection passes"
             (valid-persistence-projection? synthetic))

(test-assert "invalid backing is rejected"
             (not (false-if-exception
                    (valid-persistence-projection?
                      (projection #:backing "../escape")))))

(test-assert "invalid exposure is rejected"
             (not (false-if-exception
                    (valid-persistence-projection?
                      (projection #:exposure 'symlink)))))

(test-assert "user owner without owner-user is rejected"
             (not (false-if-exception
                    (valid-persistence-projection?
                      (persistence-projection
                        (name 'bad)
                        (root (string-append %base "/persist"))
                        (backing "state")
                        (consumer (string-append %base "/consumer"))
                        (owner 'user))))))

(test-assert "file-system is a bind mount at root/backing"
             (let ((fs (persistence-projection-file-system synthetic)))
               (and (string=? (file-system-device fs)
                              (string-append %base "/persist/state"))
                    (string=? (file-system-mount-point fs)
                              (string-append %base "/consumer"))
                    (equal? (file-system-flags fs) '(bind-mount))
                    (file-system-create-mount-point? fs))))

(test-assert "file exposure disables file-system create-mount-point"
             (let ((fs (persistence-projection-file-system
                         (projection #:exposure 'bind-file
                                     #:consumer
                                     (string-append %base "/consumer-file")))))
               (not (file-system-create-mount-point? fs))))

(define set
  (persistence-set (projections (list synthetic))))

(test-assert "set file-systems are one per projection"
             (= 1 (length (persistence-set-file-systems set))))

(test-assert "set service is a single activation service"
             (let ((svc (persistence-set-service set)))
               (eq? 'persistence (service-type-name (service-kind svc)))))

;; ── Execute the generated activation in a synthetic tree ────────────────
(define store
  (open-connection))

(define (run-activation! s)
  (let* ((drv (run-with-store store
                (gexp->script "persistence-activation-test"
                              (persistence-set-activation s))))
         (script (if (string? drv)
                     drv
                     (begin
                       (build-derivations store (list drv))
                       (derivation->output-path drv)))))
    (unless (zero? (system* script))
      (error "synthetic persistence activation failed"))))
(let* ((root (fresh-directory "run-persist"))
       (consumer (string-append %base "/run-consumer"))
       (seed-source (plain-file "synthetic-seed.txt" "synthetic\n"))
       (s (persistence-set
            (projections
             (list (projection
                     #:name 'directory
                     #:root root
                     #:backing "directory-state"
                     #:consumer consumer
                     #:owner 'user
                     #:mode #o700
                     #:seeds `(("nested/seed.txt" ,seed-source)))
                   (projection
                     #:name 'file
                     #:root root
                     #:backing "file-state"
                     #:consumer (string-append %base "/run-consumer-file")
                     #:exposure 'bind-file
                     #:owner 'user
                     #:mode #o600)
                   (projection
                     #:name (quote home)
                     #:root root
                     #:backing "home-state"
                     #:consumer (string-append %base "/run-home/.config/synthetic")
                     #:owner (quote user)
                     #:home (string-append %base "/run-home")
                     #:home-mode #o700))))))
  (remove-tree consumer)
  (remove-tree (string-append %base "/run-consumer-file"))
  (run-activation! s)
  (test-assert "activation creates directory backing and consumer"
               (and (file-exists? (string-append root "/directory-state"))
                    (eq? 'directory (stat:type (stat consumer)))))
  (test-assert "activation creates file backing and consumer"
               (and (file-exists? (string-append root "/file-state"))
                    (file-exists? (string-append %base "/run-consumer-file"))))
  (test-assert "seed-once target and marker are created"
               (let ((dest (string-append root
                                          "/directory-state/nested/seed.txt"))
                     (marker (string-append root
                                            "/directory-state/nested/seed.txt"
                                            %seed-marker-suffix)))
                 (and (file-exists? dest)
                      (file-exists? marker)
                      (string=? "synthetic\n"
                                (call-with-input-file dest
                                  get-string-all)))))
  (test-assert "home ownership and mode are applied"
               (let ((st (stat (string-append %base "/run-home"))))
                 (= #o700 (logand (stat:mode st) #o777))))
  (test-assert "mode is applied to the backing"
               (let ((st (stat (string-append root "/directory-state"))))
                 (= #o700 (logand (stat:mode st) #o777))))
  (remove-tree root)
  (remove-tree consumer)
  (remove-tree (string-append %base "/run-consumer-file")))

(remove-tree %base)
(test-end "persistence-projection")
