;;; Godot application unit: native-Wayland Godot 4 editor and game engine.
;;;
;;; The packaged desktop entry invokes Godot by its absolute store path, so a
;;; PATH wrapper would not affect launches from Niri.  A small wrapper package
;;; and user-level desktop entry keep --display-driver wayland effective for
;;; terminal, desktop-entry, and file-association launches without deriving a
;;; modified Godot editor.
;;;
;;; Persistence boundary (Godot 4 XDG paths):
;;;   - ~/.config/godot: editor settings, layouts, and script templates;
;;;   - ~/.local/share/godot: export templates, editor data, and default
;;;     project user:// data;
;;;   - ~/.cache/godot: derived cache, intentionally ephemeral.
;;; Projects themselves belong under the already-persistent ~/Projects tree.

(define-module (guixcfg apps godot definition)
  #:use-module (gnu packages game-development) ;godot (4.x)
  #:use-module (gnu home services) ;home-files-service-type
  #:use-module (gnu services) ;simple-service
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp) ;program-file / file-append / mixed-text-file
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages) ;package
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg system application-persistence)
  #:export (%godot))

(define %godot-wayland-command
  (program-file "godot"
                #~(apply execl
                         #$(file-append godot "/bin/godot")
                         "godot"
                         "--display-driver"
                         "wayland"
                         (cdr (command-line)))))

(define godot/wayland
  (package
    (name "godot-wayland")
    (version (package-version godot))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:modules '((guix build utils))
           #:builder
           #~(begin
               (use-modules (guix build utils))
               (mkdir-p (string-append #$output "/bin"))
               (copy-file #$%godot-wayland-command
                          (string-append #$output "/bin/godot"))
               (chmod (string-append #$output "/bin/godot") #o555))))
    (home-page "https://godotengine.org/")
    (synopsis "Wayland Godot editor launcher")
    (description "Launcher for Godot that forces its native Wayland display driver.")
    (license license:expat)))

(define %godot-wayland-desktop-file
  (mixed-text-file "godot.desktop"
                   "[Desktop Entry]\n"
                   "Name=Godot Engine\n"
                   "GenericName=Libre game engine\n"
                   "Comment=Multi-platform 2D and 3D game engine with a feature-rich editor\n"
                   "Exec=" (file-append godot/wayland "/bin/godot") " %f\n"
                   "Icon=" (file-append godot "/share/icons/hicolor/scalable/apps/godot.svg") "\n"
                   "Terminal=false\n"
                   "Type=Application\n"
                   "MimeType=application/x-godot-project;\n"
                   "Categories=Development;IDE;\n"
                   "StartupWMClass=Godot\n"))

(define %godot
  (application (name 'godot)
                (home-packages (list godot/wayland))
                (home-services (list (simple-service 'godot-wayland-desktop-entry
                                                     home-files-service-type
                                                     `((".local/share/applications/godot.desktop"
                                                        ,%godot-wayland-desktop-file)))))
                (persistence (list (application-persistence-rule (name 'config)
                                                                (backing
                                                                 "godot/config")
                                                                (consumer
                                                                 ".config/godot")
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned))
                                  (application-persistence-rule (name 'data)
                                                                (backing
                                                                 "godot/data")
                                                                (consumer
                                                                 ".local/share/godot")
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned))))))
