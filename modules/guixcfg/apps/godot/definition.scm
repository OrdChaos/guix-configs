;;; Godot application unit: Godot 4 editor and game engine.
;;;
;;; Persistence boundary (Godot 4 XDG paths):
;;;   - ~/.config/godot: editor settings, layouts, and script templates;
;;;   - ~/.local/share/godot: export templates, editor data, and default
;;;     project user:// data;
;;;   - ~/.cache/godot: derived cache, intentionally ephemeral.
;;; Projects themselves belong under the already-persistent ~/Projects tree.

(define-module (guixcfg apps godot definition)
  #:use-module (gnu packages game-development) ;godot (4.x)
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg system application-persistence)
  #:export (%godot))

(define %godot
  (application
   (name 'godot)
   (home-packages (list godot))
   (persistence
    (list (application-persistence-rule
           (name 'config)
           (backing "godot/config")
           (consumer ".config/godot")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'data)
           (backing "godot/data")
           (consumer ".local/share/godot")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
