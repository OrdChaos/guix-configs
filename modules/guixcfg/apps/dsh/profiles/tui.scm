;;; DSH TUI profile: base extensions + the terminal frontend.

(define-module (guixcfg apps dsh profiles tui)
  #:use-module (guix gexp) ;plain-file
  #:use-module (guix packages) ;base32
  #:use-module (guixcfg apps dsh extensions)
  #:use-module (virelith packages dsh-profiles)
  #:export (dsh-profile-tui))

(define-public dsh-profile-tui
  (dsh-profile "tui"
               #:bundles (dsh-extensions-for-profile '(tui))
               #:patch (plain-file "dsh-tui-cordis.patch.yml" "[]\n")
               ;; dsh-TUI resolves its DSH peer imports from a sibling
               ;; @deepseek-ai/dsh installation, not from Guix's store.
               #:extra-dependencies
               '(("@deepseek-ai/dsh" . "0.2.1-rc.5"))
               #:auto-install-peers? #t
               ;; The extension package is already patched at build time;
               ;; profile consumes that artifact instead of the registry copy.
               #:bundle-sources (dsh-extension-sources '(tui))
               ;; Replaced with the hash reported by the first build.
               #:specs-hash
               (base32
                "1sv6p8q05r2vmb26wh5q140m4g0ia3qk0varhyqyv1iy15fz6qpd")))
