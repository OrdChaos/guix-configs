;;; DSH application unit: DeepSeek Harness CLI/web/TUI.
;;;
;;; DSH keeps all user data under one root.  This repo uses
;;; $HOME/.local/share/dsh (DSH_HOME) and keeps the shared agent root inside
;;; it (DSH_AGENTS_HOME=$DSH_HOME/agents); the upstream ~/.agents sharing
;;; policy is deliberately not used.
;;;
;;; Frontends are profile composition, not separate runtimes:
;;;   web = base extensions + dsh-web-app
;;;   tui = base extensions + dsh-TUI
;;; The profile registry under profiles/ is the only data entry; every
;;; profile artifact is projected as ordinary Home store symlinks.  DSH may
;;; read them, but Settings/Config editor writes target the profile patch and
;;; therefore fail closed on the read-only symlink.
;;;
;;; The TUI's own preference directory is patched to
;;; $HOME/.local/share/dsh-tui and persisted separately from DSH_HOME.

(define-module (guixcfg apps dsh definition)
  #:use-module (gnu home services) ;home-environment-variables-service-type
  #:use-module (gnu services) ;simple-service
  #:use-module (guix gexp) ;file-append
  #:use-module (guixcfg apps dsh profiles)
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg system application-persistence)
  #:use-module (srfi srfi-1) ;append-map
  #:use-module (virelith packages deepseek-harness)
  #:export (%dsh))

(define (profile-key-string entry)
  (symbol->string (dsh-profile-entry-key entry)))

(define (profile-artifact-file entry name)
  (file-append (dsh-profile-entry-package entry)
               "/share/dsh/profiles/"
               (profile-key-string entry)
               "/"
               name))

(define (profile-home-file entry name)
  (string-append ".local/share/dsh/profiles/"
                 (profile-key-string entry)
                 "/"
                 name))

(define (profile-files entry)
  (append
   (map (lambda (name)
          (list (profile-home-file entry name)
                (profile-artifact-file entry name)))
        '("package.json"
          "pnpm-workspace.yaml"
          "cordis.patch.yml"))
   (if (dsh-profile-entry-external? entry)
       (list (list (profile-home-file entry "node_modules")
                   (profile-artifact-file entry "node_modules")))
       '())))

(define %dsh-profile-files
  (append-map profile-files %dsh-profiles))

(define %dsh
  (application
   (name 'dsh)
   (home-packages (list deepseek-harness))
   (home-services
    (list (simple-service 'dsh-environment
                          home-environment-variables-service-type
                          '(("DSH_HOME" . "$HOME/.local/share/dsh")
                            ("DSH_AGENTS_HOME"
                             .
                             "$HOME/.local/share/dsh/agents")
                            ("DSH_TUI_DATA_DIR"
                             .
                             "$HOME/.local/share/dsh-tui")))
          (simple-service 'dsh-profiles
                          home-files-service-type
                          %dsh-profile-files)))
   (persistence
    (list (application-persistence-rule
           (name 'data)
           (backing "dsh/data")
           (consumer ".local/share/dsh")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'tui)
           (backing "dsh-tui/data")
           (consumer ".local/share/dsh-tui")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
