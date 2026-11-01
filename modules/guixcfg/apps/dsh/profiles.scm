;;; DSH profile composition for the guix configuration repository.
;;;
;;; The profile is one dependency-resolution boundary.  In-box bundles are
;;; named directly; external bundles are dsh-npm-bundle descriptors added to
;;; this list.  dsh-profile generates the manifest and, when external bundles
;;; are present, resolves their closure into an immutable artifact pinned by
;;; SPECS-HASH.  No pnpm lockfile is committed.

(define-module (guixcfg apps dsh profiles)
  #:use-module (guix gexp) ;local-file
  #:use-module (srfi srfi-1) ;any
  #:use-module (virelith packages dsh-profiles)
  #:export (%dsh-guix-web-bundles
            %dsh-guix-web-external?
            %dsh-guix-web-profile))

(define %dsh-guix-web-bundles
  (list "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-web-app"))

(define %dsh-guix-web-external?
  (any (lambda (entry) (not (string? entry)))
       %dsh-guix-web-bundles))

;; Set to the recursive sha256 of the external closure when the bundle list
;; contains a dsh-npm-bundle descriptor.  Ignored for in-box-only profiles.
(define %dsh-guix-web-specs-hash #f)

(define %dsh-guix-web-profile
  (dsh-profile "guix-web"
               #:bundles %dsh-guix-web-bundles
               #:patch (local-file "profiles/guix-web/cordis.patch.yml")
               #:specs-hash %dsh-guix-web-specs-hash))
