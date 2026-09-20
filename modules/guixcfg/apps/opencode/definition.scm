;;; opencode application unit: OpenCode CLI from the Virelith channel.
;;;
;;; Package/runtime integration belongs to the channel package.  This module
;;; only installs it into Guix Home and declares its mutable XDG state.
;;;
;;; Persistence boundary (OpenCode 1.18.31 source audit):
;;;   ~/.config/opencode       global config, agents, commands, plugins, skills
;;;   ~/.local/share/opencode  credentials, database, sessions and worktrees
;;;   ~/.local/state/opencode  model preference, plugin metadata, daemon state
;;;   ~/.cache/opencode        downloaded/rebuildable cache; not persisted

(define-module (guixcfg apps opencode definition)
               #:use-module (virelith packages opencode)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%opencode))

(define %opencode
  (application
   (name 'opencode)
   (home-packages (list opencode-bin))
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
