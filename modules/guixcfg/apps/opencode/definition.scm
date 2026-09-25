;;; opencode application unit: OpenCode CLI from the Virelith channel.
;;;
;;; The pinned channel launcher omits xdg-utils even though OpenCode invokes
;;; xdg-open for local URLs.  Keep the corrective runtime input scoped here
;;; until the channel package includes it.
;;;
;;; Persistence boundary (OpenCode 1.18.31 source audit):
;;;   ~/.config/opencode       global config, agents, commands, plugins, skills
;;;   ~/.local/share/opencode  credentials, database, sessions and worktrees
;;;   ~/.local/state/opencode  model preference, plugin metadata, daemon state
;;;   ~/.cache/opencode        downloaded/rebuildable cache; not persisted

(define-module (guixcfg apps opencode definition)
                #:use-module (virelith packages opencode)
                #:use-module (gnu packages freedesktop) ; xdg-utils
                #:use-module (guix gexp)                ; #~ / #$
                #:use-module (guix packages)
                #:use-module (guix utils)               ; substitute-keyword-arguments
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
                #:export (%opencode))

(define opencode-bin/with-xdg-open
  (package/inherit
   opencode-bin
   (inputs
    `(("xdg-utils" ,xdg-utils)
      ,@(package-inputs opencode-bin)))
   (arguments
    (substitute-keyword-arguments (package-arguments opencode-bin)
      ((#:phases phases)
       #~(modify-phases #$phases
           (add-after 'install-launcher 'add-xdg-open
             (lambda _
               (wrap-program (string-append #$output "/bin/opencode")
                 `("PATH" ":" prefix
                   (,(string-append #$(this-package-input "xdg-utils")
                                     "/bin"))))))))))))

(define %opencode
  (application
   (name 'opencode)
    (home-packages (list opencode-bin/with-xdg-open))
   (persistence
    (list (application-persistence-rule
           (name 'config)
           (backing "opencode/config")
           (consumer ".config/opencode")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'data)
           (backing "opencode/data")
           (consumer ".local/share/opencode")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'state)
           (backing "opencode/state")
           (consumer ".local/state/opencode")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
