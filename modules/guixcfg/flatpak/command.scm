;;; Blue Flatpak command adapter, loaded only by the public flatpak command.

(define-module (guixcfg flatpak command)
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg flatpak reconcile)
               #:use-module (guixcfg flatpak registry)
               #:use-module (ice-9 format)
               #:use-module (ice-9 ftw)                  ; dirname
               #:use-module (ice-9 match)
               #:use-module (srfi srfi-11)               ; let-values
               #:use-module (srfi srfi-13)               ; string-join
               #:use-module (srfi srfi-26)               ; cut
               #:export (run-flatpak-command))

(define (exception-strings exn-args)
  (let walk ((x exn-args))
    (cond ((string? x) (list x))
          ((symbol? x) (list (symbol->string x)))
          ((pair? x) (append (walk (car x)) (walk (cdr x))))
          (else '()))))

(define (usage-error)
  (format (current-error-port)
          "Usage: blue flatpak ACTION [ARGS...]~%actions: ~a~%"
          (string-join (flatpak-actions) ", "))
  (primitive-exit 1))

(define (print-lines lines)
  (for-each (lambda (line) (format #t "~a~%" line)) lines))

(define (local-selections _allow-default?)
  "Flatpak selections：全局用户软件 policy（所有设备一致）。硬件驱动
差异不通过 selection 表达——desired app/extension 集合不再依赖
hostname 或 host 模块（docs/architecture/flatpak.md）。"
  (values %flatpak-selection %flatpak-extension-selection))

(define (run-flatpak-command arguments dry-run?)
  "Run the validated user-scope Flatpak command represented by ARGUMENTS.
DRY-RUN? selects read-only plans for mutating actions."
  (catch #t
    (lambda ()
      (when (zero? (getuid))
        (format (current-error-port)
                "flatpak: refusing to run as root (all operations are --user scope; root would act on /root/.local/share/flatpak, not your user installation).~%")
        (primitive-exit 1))
      (let ((binary (flatpak-binary)))
        (setenv "FLATPAK_BINARY" binary)
        (setenv "PATH" (string-append (dirname binary)
                                      ":"
                                      (or (getenv "PATH") ""))))
      (match (flatpak-validate-action-arguments
              (and (pair? arguments) (car arguments))
              (if (pair? arguments) (cdr arguments) '()))
        (#f (usage-error))
        (('status ())
         (let-values (((selection extension-selection)
                       (local-selections #t)))
           (flatpak-status #:selection selection
                           #:extension-selection extension-selection)))
        (('status (refresh))
         (let-values (((selection extension-selection)
                       (local-selections #t)))
           (flatpak-status #:refresh? #t
                           #:selection selection
                           #:extension-selection extension-selection)))
        (('sync ())
         (let-values (((selection extension-selection)
                       (local-selections #f)))
           (if dry-run?
             (print-lines
              (flatpak-sync-plan %flatpak-remotes
                                 %flatpak-applications
                                 selection
                                 #:extensions %flatpak-extensions
                                 #:extension-selection extension-selection))
             (flatpak-sync #:selection selection
                           #:extensions %flatpak-extensions
                           #:extension-selection extension-selection))))
        (('update ())
         (let-values (((selection extension-selection)
                       (local-selections #f)))
           (if dry-run?
             (let ((refs (flatpak-update-plan
                          %flatpak-applications selection
                          #:extensions %flatpak-extensions
                          #:extension-selection extension-selection)))
               (if (null? refs)
                 (format #t "No unpinned selected applications to update.~%")
                 (print-lines
                  (map (cut format #f "would update ~a" <>) refs))))
             (flatpak-update #:selection selection
                             #:extensions %flatpak-extensions
                             #:extension-selection extension-selection))))
        (('update-runtimes ())
         (if dry-run?
           (let ((refs (flatpak-update-runtimes-plan)))
             (if (null? refs)
               (format #t "No installed runtimes to update.~%")
               (print-lines
                (map (cut format #f "would update runtime ~a" <>) refs))))
            (flatpak-update-runtimes)))
        (('remove (name))
         (if dry-run?
           (let ((app (flatpak-remove-plan (string->symbol name)
                                           %flatpak-applications)))
             (format #t "would uninstall ~a (user data under ~~/.var/app/~a preserved)~%"
                     (flatpak-application-id app)
                     (flatpak-application-id app)))
            (flatpak-remove (string->symbol name))))
        (('remote-replace (name))
         (let ((remote (flatpak-remote-by-name (string->symbol name))))
           (if dry-run?
             (let ((current (flatpak-replace-remote-plan remote)))
               (format #t "remote ~a: current url ~a~%"
                       name (or current "(not configured)"))
               (format #t (if current
                            "would explicitly delete the existing remote and rebuild it~%"
                            "would add the remote (bootstrap + canonicalize)~%"))
               (format #t "  descriptor: ~a~%  transport:  ~a~%"
                       (flatpak-remote-descriptor-url remote)
                       (flatpak-remote-repository-url remote)))
              (flatpak-replace-remote! remote))))
        (('gc ())
         (let-values (((_selection extension-selection)
                       (local-selections #f)))
           (if dry-run?
             (begin
               (format #t "gc preview (unused refs cannot be enumerated without mutation):~%")
               (print-lines
                (map (cut format #f "  would unpin extension ~a" <>)
                     (flatpak-gc-unpin-plan
                      #:extensions %flatpak-extensions
                      #:extension-selection extension-selection)))
               (print-lines
                (map (lambda (argv) (format #f "  ~{ ~a~}" argv))
                     (flatpak-gc-commands))))
             (flatpak-gc #:extensions %flatpak-extensions
                         #:extension-selection extension-selection))))))
    (lambda (key . args)
      (format (current-error-port) "flatpak: ~a~%"
              (string-join (exception-strings args) " "))
      (primitive-exit 1))))
