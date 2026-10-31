;;; DSH application unit: DeepSeek Harness CLI/web.
;;;
;;; DSH keeps all user data under one root.  This repo uses
;;; $HOME/.local/share/dsh (DSH_HOME) and keeps the shared agent root inside
;;; it (DSH_AGENTS_HOME=$DSH_HOME/agents); the upstream ~/.agents sharing
;;; policy is deliberately not used.
;;;
;;; The profile root is a mixed-authority container:
;;;   repo-owned: package.json, pnpm-workspace.yaml, cordis.patch.yml
;;;   DSH-owned:  cordis.yml, sessions, storages, credentials, logs, cache
;;; managed-files copies the repo-owned files during Home activation; it
;;; never deletes unlisted files.  The profile only uses in-box bundles, so
;;; no node_modules tree is materialized.
;;;
;;; No runtime pnpm/network install path is exposed.  Plugin/profile changes
;;; are repository changes followed by reconfigure.  Invoke the profile as
;;; `dsh guix-web'.  For the first deployment, reconfigure the system before
;;; Home so the persistence bind exists when managed-files runs.

(define-module (guixcfg apps dsh definition)
  #:use-module (gnu home services) ;home-environment-variables-service-type
  #:use-module (gnu services) ;simple-service
  #:use-module (guix gexp) ;local-file
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg home managed-files)
  #:use-module (guixcfg system application-persistence)
  #:use-module (virelith packages deepseek-harness)
  #:export (%dsh))

(define %dsh-profile-directory
  ".local/share/dsh/profiles/guix-web")

(define %dsh-profile-files
  (list (managed-file (name 'package)
                      (target (string-append %dsh-profile-directory
                                             "/package.json"))
                      (source (local-file "profiles/guix-web/package.json"
                                          "dsh-guix-web-package.json")))
        (managed-file (name 'workspace)
                      (target (string-append %dsh-profile-directory
                                             "/pnpm-workspace.yaml"))
                      (source (local-file
                               "profiles/guix-web/pnpm-workspace.yaml"
                               "dsh-guix-web-workspace.yaml")))
        (managed-file (name 'patch)
                      (target (string-append %dsh-profile-directory
                                             "/cordis.patch.yml"))
                      (source (local-file
                               "profiles/guix-web/cordis.patch.yml"
                               "dsh-guix-web-cordis.patch.yml")))))

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
                             "$HOME/.local/share/dsh/agents")))
          (simple-service 'dsh-profile
                          managed-files-service-type
                          %dsh-profile-files)))
   (persistence
    (list (application-persistence-rule
           (name 'data)
           (backing "dsh/data")
           (consumer ".local/share/dsh")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
