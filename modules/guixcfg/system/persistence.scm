;;; Generic persistence projection / set executor.
;;;
;;; One projection expresses one canonical backing and its consumer:
;;;
;;;   root/backing  → bind → consumer
;;;
;;; The same projection derives both:
;;;   - the bind file-system (file-systems stage);
;;;   - the activation that creates backing/consumer and ownership.
;;;
;;; A persistence set is a list of projections.  Hosts pass ONE set to the
;;; base OS and to service assembly; no separate file-system/activation lists.
;;;
;;; This module is mechanism only: it knows roots, backing/consumer,
;;; exposure, owner, mode, options and seed-once.  It does not know
;;; application names, host names, users, or storage-subvolume names.
;;;
;;; Excluded by design: secrets, immutable store mounts, direct-reference
;;; state (SSH keys/machine-id/TPM) and Guix Home derived state.

(define-module (guixcfg system persistence)
  #:use-module (gnu services) ;simple-service
  #:use-module (gnu system file-systems) ;file-system
  #:use-module (guix gexp)
  #:use-module (guix modules) ;source-module-closure
  #:use-module (guix records)
  #:use-module (guixcfg utils home-path) ;ensure-home-parent-directories!
  #:use-module (guixcfg utils module-closure) ;guixcfg-module-select?
  #:use-module (guixcfg utils paths) ;valid-relative-path?
  #:use-module (guixcfg utils seed-once) ;seed-once-file!、%seed-marker-suffix
  #:use-module (srfi srfi-1) ;any、filter
  #:export (<persistence-projection> persistence-projection
            make-persistence-projection persistence-projection?
            persistence-projection-name
            persistence-projection-root
            persistence-projection-backing
            persistence-projection-consumer
            persistence-projection-exposure
            persistence-projection-owner
            persistence-projection-owner-user
            persistence-projection-owner-group
            persistence-projection-mode
            persistence-projection-options
            persistence-projection-home
            persistence-projection-home-mode
            persistence-projection-seeds
            valid-persistence-projection?
            persistence-projection-file-system

            <persistence-set> persistence-set
            make-persistence-set persistence-set?
            persistence-set-projections
            persistence-set-file-systems
            persistence-set-activation
            persistence-set-service))

(define %allowed-exposures
  '(bind-directory bind-file))

(define %allowed-owners
  '(root user named))

(define-record-type* <persistence-projection>
                     persistence-projection
                     make-persistence-projection
  persistence-projection?
  (name persistence-projection-name) ;symbol
  (root persistence-projection-root) ;absolute persist root
  (backing persistence-projection-backing) ;relative to root
  (consumer persistence-projection-consumer) ;absolute mount point
  (exposure persistence-projection-exposure ;bind-directory | bind-file
            (default 'bind-directory))
  (owner persistence-projection-owner ;root | user | named
         (default 'root))
  (owner-user persistence-projection-owner-user ;string or #f
              (default #f))
  (owner-group persistence-projection-owner-group ;string or #f
               (default #f))
  (mode persistence-projection-mode ;integer or #f
        (default #f))
  (options persistence-projection-options ;string or #f
           (default #f))
  (home persistence-projection-home ;absolute HOME or #f
        (default #f))
  (home-mode persistence-projection-home-mode ;integer or #f
             (default #f))
  (seeds persistence-projection-seeds ;list of (target source)
         (default '())))

(define-record-type* <persistence-set>
                     persistence-set
                     make-persistence-set
  persistence-set?
  (projections persistence-set-projections (default '())))

(define (validate-seed-spec spec)
  (unless (and (list? spec)
               (= 2 (length spec))
               (string? (car spec)))
    (error "persistence seed must be a (target source) pair" spec))
  (unless (valid-relative-path? (car spec))
    (error "persistence seed target must be a safe relative path" spec)))

(define (valid-persistence-projection? projection)
  "Validate a projection independently of any host/application.  Return #t or
signal an error with a precise message.  No path/name is hard-coded except the
mechanism's absolute-vs-relative shape."
  (define (require condition message)
    (unless condition (error message projection)))
  (require (symbol? (persistence-projection-name projection))
           "persistence projection name must be a symbol")
  (require (and (string? (persistence-projection-root projection))
                (string-prefix? "/" (persistence-projection-root projection)))
           "persistence projection root must be absolute")
  (require (valid-relative-path?
            (persistence-projection-backing projection))
           "persistence projection backing must be a safe relative path")
  (require (and (string? (persistence-projection-consumer projection))
                (string-prefix? "/" (persistence-projection-consumer projection)))
           "persistence projection consumer must be absolute")
  (require (memq (persistence-projection-exposure projection)
                 %allowed-exposures)
           "persistence projection exposure is not supported")
  (require (memq (persistence-projection-owner projection)
                 %allowed-owners)
           "persistence projection owner is not supported")
  (when (memq (persistence-projection-owner projection) '(user named))
    (require (string? (persistence-projection-owner-user projection))
             "user/named persistence projection requires owner-user"))
  (when (persistence-projection-owner-group projection)
    (require (string? (persistence-projection-owner-group projection))
             "persistence projection owner-group must be a string or #f"))
  (when (persistence-projection-mode projection)
    (require (integer? (persistence-projection-mode projection))
             "persistence projection mode must be an integer or #f"))
  (when (persistence-projection-options projection)
    (require (string? (persistence-projection-options projection))
             "persistence projection options must be a string or #f"))
  (when (persistence-projection-home projection)
    (require (and (string? (persistence-projection-home projection))
                  (string-prefix? "/" (persistence-projection-home projection)))
             "persistence projection home must be absolute or #f"))
  (when (persistence-projection-home-mode projection)
    (require (integer? (persistence-projection-home-mode projection))
             "persistence projection home-mode must be an integer or #f"))
  (for-each validate-seed-spec (persistence-projection-seeds projection))
  #t)

(define (persistence-projection-file-system projection)
  "Return the bind file-system for PROJECTION.  File and directory exposure
both use a bind mount; a file consumer is not created by the file-system
stage (activation creates the regular-file mount point)."
  (valid-persistence-projection? projection)
  (file-system
    (device (string-append (persistence-projection-root projection)
                           "/"
                           (persistence-projection-backing projection)))
    (mount-point (persistence-projection-consumer projection))
    (type "none")
    (flags '(bind-mount))
    (options (or (persistence-projection-options projection) ""))
    (create-mount-point? (eq? (persistence-projection-exposure projection)
                              'bind-directory))
    (check? #f)))

(define (persistence-set-file-systems set)
  (map persistence-projection-file-system
       (persistence-set-projections set)))

(define (seed-expression seed)
  #~(list #$(car seed) #$(cadr seed)))

(define (projection-expression projection)
  #~(list '#$(persistence-projection-name projection)
          #$(persistence-projection-root projection)
          #$(persistence-projection-backing projection)
          #$(persistence-projection-consumer projection)
          '#$(persistence-projection-exposure projection)
          '#$(persistence-projection-owner projection)
          #$(or (persistence-projection-owner-user projection) "")
          #$(or (persistence-projection-owner-group projection) "")
          #$(or (persistence-projection-mode projection) 0)
          #$(or (persistence-projection-options projection) "")
          #$(or (persistence-projection-home projection) "")
          #$(or (persistence-projection-home-mode projection) 0)
          (list #$@(map seed-expression
                        (persistence-projection-seeds projection)))))

(define (persistence-set-activation set)
  "Return one activation gexp for all projections, or #f for an empty set."
  (let ((projections (persistence-set-projections set)))
    (for-each valid-persistence-projection? projections)
    (if (null? projections)
        #f
        (with-imported-modules
          (source-module-closure '((guix build utils)
                                   (guixcfg utils home-path)
                                   (guixcfg utils seed-once))
                                 #:select? guixcfg-module-select?)
          #~(begin
              (use-modules (guix build utils)
                           (guixcfg utils home-path)
                           (guixcfg utils seed-once)
                           (ice-9 rdelim))
              (define (owner-ids owner owner-user owner-group)
                (if (eq? owner 'root)
                    (values 0 0)
                    (let* ((pw (getpw owner-user))
                           (gid (if (string=? owner-group "")
                                    (passwd:gid pw)
                                    (group:gid (getgrnam owner-group)))))
                      (values (passwd:uid pw) gid))))
              (define (ensure-backing-parents root src uid gid)
                (let loop ((dir (dirname src)))
                  (when (and (string-prefix? (string-append root "/") dir)
                             (not (string=? dir root)))
                    (chown dir uid gid)
                    (loop (dirname dir)))))
              (define (ensure-home home home-mode uid gid)
                (mkdir-p home)
                (chown home uid gid)
                (when (> home-mode 0) (chmod home home-mode)))
              (define (home-relative consumer home)
                (unless (string-prefix? (string-append home "/") consumer)
                  (error "persistence consumer is outside home" consumer home))
                (substring consumer (1+ (string-length home))))
              (define (ensure-directory path uid gid mode)
                (mkdir-p path)
                (chown path uid gid)
                (when (> mode 0) (chmod path mode)))
              (define (ensure-file path uid gid mode)
                (mkdir-p (dirname path))
                (if (file-exists? path)
                    (unless (eq? 'regular (stat:type (stat path)))
                      (error "persistence file path is not regular" path))
                    (call-with-output-file path (lambda (port) #t)))
                (chown path uid gid)
                (when (> mode 0) (chmod path mode)))
              (define (apply-seeds src uid gid seeds)
                (for-each (lambda (seed)
                            (let* ((target (car seed))
                                   (source (cadr seed))
                                   (dest (string-append src "/" target))
                                   (marker (string-append dest
                                                          %seed-marker-suffix)))
                              (mkdir-p (dirname dest))
                              ;; Every newly created intermediate seed directory
                              ;; belongs to the consumer owner, not root.
                              (let loop ((dir (dirname dest)))
                                (unless (string=? dir src)
                                  (chown dir uid gid)
                                  (loop (dirname dir))))
                              (case (seed-once-file! dest source marker)
                                ((seeded)
                                 (chown dest uid gid)
                                 (chown marker uid gid))
                                ((preserved)
                                 (chown marker uid gid)))))
                          seeds))
              (for-each
                (lambda (spec)
                  (let* ((name (list-ref spec 0))
                         (root (list-ref spec 1))
                         (backing (list-ref spec 2))
                         (consumer (list-ref spec 3))
                         (exposure (list-ref spec 4))
                         (owner (list-ref spec 5))
                         (owner-user (list-ref spec 6))
                         (owner-group (list-ref spec 7))
                         (mode (list-ref spec 8))
                         (options (list-ref spec 9))
                         (home (list-ref spec 10))
                         (home-mode (list-ref spec 11))
                         (seeds (list-ref spec 12))
                         (src (string-append root "/" backing)))
                    (call-with-values
                      (lambda () (owner-ids owner owner-user owner-group))
                      (lambda (uid gid)
                        (when (not (string=? home ""))
                          (ensure-home home home-mode uid gid))
                        (if (string=? home "")
                            (mkdir-p (dirname consumer))
                            (ensure-home-parent-directories!
                              home (home-relative consumer home) uid gid))
                        (case exposure
                          ((bind-directory)
                           (ensure-directory src uid gid mode)
                           (ensure-backing-parents root src uid gid)
                           (ensure-directory consumer uid gid mode)
                           (apply-seeds src uid gid seeds))
                          ((bind-file)
                           (ensure-file src uid gid mode)
                           (ensure-backing-parents root src uid gid)
                           (ensure-file consumer uid gid mode)
                           (unless (null? seeds)
                             (error "bind-file persistence does not support seeds"
                                    name)))
                          (else
                           (error "unknown persistence exposure" exposure)))))))
                (list #$@(map projection-expression projections))))))))

(define (persistence-set-service set)
  "Return a single activation service for SET, or #f for an empty set."
  (let ((activation (persistence-set-activation set)))
    (if activation
        (simple-service 'persistence activation-service-type activation)
        #f)))
