;;; DSH TUI profile: base extensions + the terminal frontend.

(define-module (guixcfg apps dsh profiles tui)
  #:use-module (guix gexp) ;file-append、plain-file
  #:use-module (guix packages) ;base32
  #:use-module (guixcfg apps dsh extensions)
  #:use-module (virelith packages deepseek-harness)
  #:use-module (virelith packages dsh-profiles)
  #:export (dsh-profile-tui))

(define-public dsh-profile-tui
  (dsh-profile "tui"
               #:bundles (dsh-extensions-for-profile '(tui))
               #:patch (plain-file "dsh-tui-cordis.patch.yml" "[]\n")
               ;; Share the launching DSH runtime's module identity.  A
               ;; second npm @deepseek-ai/dsh copy makes config-editor and
               ;; app-boot separate instances, so profile reload cannot find
               ;; the root Include mounted by the CLI.
               #:runtime-scope (file-append deepseek-harness
                                "/libexec/deepseek-harness/node_modules/.pnpm/node_modules/@deepseek-ai")
               ;; The extension package is already patched at build time;
               ;; profile consumes that artifact instead of the registry copy.
               #:bundle-sources (dsh-extension-sources '(tui))
               ;; Replaced with the hash reported by the first build.
               #:specs-hash (base32
                             "0mrap02g2gxr844s4nncpvlncxsa5gjy43d7a55jjfjgjzi4mg65")))
