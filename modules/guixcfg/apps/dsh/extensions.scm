;;; DSH extension registry: the single data entry for profile composition.
;;;
;;; Every extension is a single-file module under extensions/, exporting a
;;; value accepted by dsh-profile: an in-box bundle name string or an external
;;; dsh-npm-bundle descriptor.  Profiles refer to registered keys only; adding
;;; a new plugin means adding extensions/<name>.scm and registering it below.
;;;
;;; BASE-EXTENSIONS are prepended to every profile.  Profile-specific lists
;;; select additional keys from this registry; duplicates and unknown keys
;;; fail at evaluation time.

(define-module (guixcfg apps dsh extensions)
  #:use-module (guix gexp) ;file-append
  #:use-module (guixcfg apps dsh extensions auto-review)
  #:use-module (guixcfg apps dsh extensions base)
  #:use-module (guixcfg apps dsh extensions web-app)
  #:use-module (guixcfg apps dsh extensions tui)
  #:use-module (srfi srfi-1) ;delete-duplicates、filter-map
  #:use-module (virelith packages dsh-bundles)
  #:export (%dsh-base-extensions
            %dsh-extensions
            dsh-extension
            dsh-extensions-for-profile
            dsh-extension-sources))

(define %dsh-base-extensions
  '(base auto-review))

(define %dsh-extensions
  `((base . ,dsh-extension-base)
    (auto-review . ,dsh-extension-auto-review)
    (web-app . ,dsh-extension-web-app)
    (tui . ,dsh-extension-tui)))

(define (dsh-extension key)
  (let ((entry (assq key %dsh-extensions)))
    (unless entry
      (error "unknown DSH extension" key))
    (cdr entry)))

(define (dsh-extensions-for-profile keys)
  "Return the ordered bundle list for a profile selecting KEYS."
  (let* ((all (append %dsh-base-extensions keys))
         (unique (delete-duplicates all eq?)))
    (unless (= (length all) (length unique))
      (error "duplicate DSH extension key in profile" keys))
    (map dsh-extension all)))

(define (dsh-extension-sources keys)
  "Return (NAME . INSTALLED-PATH) for external extensions in KEYS."
  (filter-map
   (lambda (key)
     (let ((entry (dsh-extension key)))
       (and (dsh-bundle-package? entry)
            (let ((name (dsh-bundle-package-name entry)))
              (cons name
                    (file-append entry
                                 "/share/dsh/bundles/" name))))))
   keys))
