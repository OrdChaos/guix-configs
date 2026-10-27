;;; Sleepy Launcher application definition（Flatpak；
;;; docs/architecture/flatpak.md（application model））。
;;;
;;; Sleepy Launcher 与 An Anime Game Launcher 使用相同的 sandbox policy：
;;; 原生 Wayland UI、保留 X11 给 Wine 游戏，以及包内 Git helpers。

(define-module (guixcfg flatpak applications sleepy-launcher definition)
  #:use-module (guixcfg flatpak model)
  #:use-module (guixcfg system gaming)
  #:export (%flatpak-sleepy-launcher))

(define %flatpak-sleepy-launcher
  (flatpak-application
   (name 'sleepy-launcher)
   (id "moe.launcher.sleepy-launcher")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)
   (override-policy
    (list 'managed-overrides
          (flatpak-override
           (sockets (list "wayland"))
           (filesystems (list %sleepy-launcher-games-library-path))
           (environment
            '("GIT_EXEC_PATH=/app/libexec/git-core")))))))
