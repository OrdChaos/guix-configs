;;; DSH web profile: base extensions + the Web UI frontend.

(define-module (guixcfg apps dsh profiles web)
  #:use-module (guix gexp) ;plain-file
  #:use-module (guixcfg apps dsh extensions)
  #:use-module (virelith packages dsh-profiles)
  #:export (dsh-profile-web))

(define-public dsh-profile-web
  (dsh-profile "web"
               #:bundles (dsh-extensions-for-profile '(web-app))
               #:patch (plain-file "dsh-web-cordis.patch.yml" "[]\n")))
