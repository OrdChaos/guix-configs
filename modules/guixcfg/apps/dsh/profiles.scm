;;; DSH profile composition for the guix configuration repository.
;;;
;;; The profile is one dependency-resolution boundary.  In-box bundles are
;;; named directly; external bundles are dsh-npm-bundle descriptors added to
;;; this list.  dsh-profile generates the manifest, uses the committed pnpm
;;; lockfile, and emits an immutable artifact.
;;;
;;; Bump NODE-MODULES-HASH together with any bundle list or lockfile change.

(define-module (guixcfg apps dsh profiles)
  #:use-module (guix gexp) ;local-file
  #:use-module (guix packages) ;base32
  #:use-module (virelith packages dsh-profiles)
  #:export (%dsh-guix-web-bundles
            %dsh-guix-web-profile))

(define %dsh-guix-web-bundles
  (list "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-web-app"))

(define %dsh-guix-web-profile
  (dsh-profile "guix-web"
               #:bundles %dsh-guix-web-bundles
               #:lockfile (local-file "profiles/guix-web/pnpm-lock.yaml")
               #:patch (local-file "profiles/guix-web/cordis.patch.yml")
               ;; Replace after the first build reports the actual hash.
               #:node-modules-hash
               (base32 "0vghhmdmh5pcpgsghfka5vmqml7ra6kmzcyccky9zc85di2ksrs3")))
