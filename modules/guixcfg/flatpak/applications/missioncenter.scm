;;; Mission Center

(define-module (guixcfg flatpak applications missioncenter)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-missioncenter))

(define %flatpak-missioncenter
  (flatpak-application
   (name 'missioncenter)
   (id "io.missioncenter.MissionCenter")
   (remote 'flathub)
   (branch "stable")
   ))
