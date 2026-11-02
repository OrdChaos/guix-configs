;;; Repository-owned DSH skill library.
;;;
;;; Flat skills live under this module's skills/ directory and are projected
;;; into DSH's user skill root ($DSH_HOME/skills).  Keep the registry explicit:
;;; a file on disk is not installed unless it is listed here.
;;;
;;; Skills are read-only Home store links.  User-local skills stay writable
;;; under the same root, but must use a different name.

(define-module (guixcfg apps dsh skills)
  #:use-module (guixcfg utils repository-source) ;repository-file
  #:export (%dsh-skill-files))

(define %dsh-skill-directory
  ".local/share/dsh/skills")

(define (dsh-skill-target name)
  (string-append %dsh-skill-directory "/" name ".md"))

(define %dsh-skill-files
  `((,(dsh-skill-target "guix-configs") ,(repository-file
                                          "modules/guixcfg/apps/dsh/skills/guix-configs.md"))))
