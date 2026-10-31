;;; xdg-utils application unit: shared desktop integration commands.
;;;
;;; xdg-user-dirs provides the xdg-user-dir CLI.  The official Home
;;; user-directories service only writes user-dirs.dirs and creates the
;;; directories; applications that resolve user dirs at runtime (for example
;;; DSH's default-workspace initialization) need this executable on PATH.

(define-module (guixcfg apps xdg-utils definition)
  #:use-module (gnu packages freedesktop) ;xdg-utils、xdg-user-dirs
  #:use-module (guixcfg apps model)
  #:export (%xdg-utils))

(define %xdg-utils
  (application (name 'xdg-utils)
               (home-packages (list xdg-utils xdg-user-dirs))))
