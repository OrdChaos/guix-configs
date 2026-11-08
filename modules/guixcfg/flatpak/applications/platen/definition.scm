;;; Platen

(define-module (guixcfg flatpak applications platen definition)
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-platten))

(define %flatpak-platten
  (flatpak-application (name 'platen)
                       (id "page.wisha.platen")
                       (remote 'flathub)
                       (branch "stable")
                       ))
