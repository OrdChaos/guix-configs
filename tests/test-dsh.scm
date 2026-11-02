;;; DSH extension/profile registry tests.
;;;
;;; Static assertions only: no lowering, no downloads, no builds.

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (guix packages)
             (gnu services) ;service-kind、service-type-name
             (guixcfg apps dsh definition)
             (guixcfg apps dsh extensions)
             (guixcfg apps dsh profiles)
             (guixcfg apps dsh skills)
             (guixcfg apps model)
             (guixcfg system application-persistence)
             (virelith packages dsh-bundles))

(test-runner-current (test-runner-simple))
(test-begin "dsh-registries")

(test-assert "base extensions are common to every profile"
             (equal? '(base auto-review) %dsh-base-extensions))

(test-assert "web profile resolves base + auto review + web app"
             (equal? '("@deepseek-ai/dsh-base"
                       "@deepseek-ai/dsh-experimental-auto-review"
                       "@deepseek-ai/dsh-web-app")
                     (dsh-extensions-for-profile '(web-app))))

(test-assert "tui profile resolves base + auto review + TUI descriptor"
             (let ((bundles (dsh-extensions-for-profile '(tui))))
               (and (= (length bundles) 3)
                    (string=? (car bundles) "@deepseek-ai/dsh-base")
                    (string=? (cadr bundles)
                              "@deepseek-ai/dsh-experimental-auto-review")
                    (dsh-bundle-package? (caddr bundles))
                    (string=? "@deepseek-harness-tui/dsh-tui"
                              (dsh-bundle-package-name (caddr bundles))))))

(test-assert "profile registry contains web and tui"
             (equal? '(web tui)
                     (map dsh-profile-entry-key %dsh-profiles)))

(test-assert "web profile is in-box-only"
             (not (dsh-profile-entry-external? (find (lambda (entry)
                                                       (eq? 'web
                                                            (dsh-profile-entry-key
                                                             entry)))
                                                     %dsh-profiles))))

(test-assert "tui profile has an external bundle"
             (dsh-profile-entry-external? (find (lambda (entry)
                                                  (eq? 'tui
                                                       (dsh-profile-entry-key
                                                        entry))) %dsh-profiles)))

(test-assert "unknown extension key fails closed"
             (catch #t
                    (lambda ()
                      (dsh-extensions-for-profile '(does-not-exist)) #f)
                    (lambda args
                      #t)))

(test-assert "duplicate extension key fails closed"
             (catch #t
                    (lambda ()
                      (dsh-extensions-for-profile '(web-app web-app)) #f)
                    (lambda args
                      #t)))

(define %profile-files-service
  (find (lambda (service)
          (eq? 'dsh-profiles
               (service-type-name (service-kind service))))
        (application-home-services %dsh)))

(define %profile-file-targets
  (map car
       (service-value %profile-files-service)))

(test-assert "home projection includes web and tui profiles"
             (and (member ".local/share/dsh/profiles/web/package.json"
                          %profile-file-targets)
                  (member ".local/share/dsh/profiles/tui/package.json"
                          %profile-file-targets)))

(test-assert "only the external tui profile projects node_modules"
             (and (not (member ".local/share/dsh/profiles/web/node_modules"
                               %profile-file-targets))
                  (member ".local/share/dsh/profiles/tui/node_modules"
                          %profile-file-targets)))

(define %skill-files-service
  (find (lambda (service)
          (eq? 'dsh-skills
               (service-type-name (service-kind service))))
        (application-home-services %dsh)))

(test-assert "repository skill library projects into DSH_HOME"
             (member ".local/share/dsh/skills/guix-configs.md"
                     (map car
                          (service-value %skill-files-service))))

(test-assert "repository skill library has no duplicate targets"
             (let ((targets (map car
                                 (service-value %skill-files-service))))
               (= (length targets)
                  (length (delete-duplicates targets)))))

(test-assert "dsh-tui has its own persistence rule"
             (any (lambda (rule)
                    (eq? 'tui
                         (application-persistence-rule-name rule)))
                  (application-persistence %dsh)))

(test-end "dsh-registries")
