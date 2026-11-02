;;; DSH profile registry: one module per profile under profiles/.
;;;
;;; The registry is explicit, like the extension registry: adding a profile
;;; means adding profiles/<name>.scm and registering it here.  The definition
;;; consumes this list to project every profile into Home.

(define-module (guixcfg apps dsh profiles)
  #:use-module (srfi srfi-9) ;define-record-type
  #:use-module (guixcfg apps dsh profiles web)
  #:use-module (guixcfg apps dsh profiles tui)
  #:export (<dsh-profile-entry> dsh-profile-entry? dsh-profile-entry-key
                                dsh-profile-entry-package
                                dsh-profile-entry-external? %dsh-profiles))

(define-record-type <dsh-profile-entry>
  (make-dsh-profile-entry key package external?) dsh-profile-entry?
  (key dsh-profile-entry-key)
  (package
    dsh-profile-entry-package)
  (external? dsh-profile-entry-external?))

(define %dsh-profiles
  (list (make-dsh-profile-entry 'web dsh-profile-web #f)
        (make-dsh-profile-entry 'tui dsh-profile-tui #t)))
