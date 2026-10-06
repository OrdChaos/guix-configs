;;; NewsFlash Flatpak application definition

(define-module (guixcfg flatpak applications newsflash definition)
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-newsflash))

(define %flatpak-newsflash
  (flatpak-application (name 'newsflash)
                       (id "com.github.rafostar.Clapper.Enhancers")
                       (remote 'flathub)
                       (branch "stable")
                       (update-policy 'track-branch)
                       (override-policy 'external)))
