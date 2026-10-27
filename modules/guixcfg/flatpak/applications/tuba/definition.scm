;;; Tuba Flatpak application definition

(define-module (guixcfg flatpak applications tuba definition)
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-tuba %tuba-desktop-entry))

(define %tuba-desktop-entry "dev.geopjr.Tuba.desktop")

(define %flatpak-tuba
  (flatpak-application (name 'tuba)
                       (id "dev.geopjr.Tuba")
                       (remote 'flathub)
                       (branch "stable")
                       (update-policy 'track-branch)
                       (override-policy 'external)))
