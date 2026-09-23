;;; Repository-level orchestration and tracked-secret contracts.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))
(test-begin "repository-hygiene")

(define (read-file path)
  (call-with-input-file path get-string-all))

(define blueprint (read-file "blueprint.scm"))
(define command-table
  (or (string-contains blueprint "(commands (list")
      (error "blueprint command table not found")))

(test-assert "privileged deployment paths do not register root Blue commands"
             (let ((registered (substring blueprint command-table)))
               (and (string-contains registered "gc-command")
                    (not (string-contains registered "gc-root-command"))
                    (not (string-contains registered "install-root-command"))
                    (not (string-contains registered "enroll-root-command")))))

(test-assert "channel update decodes subprocess failures"
             (string-contains blueprint "(%subprocess-fail! status argv)"))

(test-assert "blueprint lazy-loads the user-only Flatpak dependency graph"
             (let* ((imports-end (or (string-contains blueprint
                                                      "(primitive-load")
                                     (error "blueprint import boundary not found")))
                    (eager-imports (substring blueprint 0 imports-end)))
               (and (not (string-contains eager-imports
                                          "(guixcfg flatpak reconcile)"))
                    (not (string-contains eager-imports
                                          "(guixcfg flatpak registry)"))
                    (string-contains blueprint
                                     "tools/flatpak.scm"))))

(define (tracked-files)
  (let* ((port (open-pipe* OPEN_READ "git" "ls-files"))
         (files (let loop ((acc '()))
                  (let ((line (read-line port)))
                    (if (eof-object? line) (reverse acc)
                      (loop (cons line acc))))))
         (status (close-pipe port)))
    (unless (zero? status)
      (error "git ls-files failed" status))
    files))

(define %private-key-markers
  (map (lambda (parts) (string-join parts ""))
       '(("AGE-" "SECRET-KEY-") ("BEGIN OPENSSH " "PRIVATE KEY")
                                ("BEGIN RSA " "PRIVATE KEY") ("BEGIN EC " "PRIVATE KEY")
                                ("BEGIN DSA " "PRIVATE KEY")
                                ("BEGIN PGP " "PRIVATE KEY BLOCK"))))

(define %tracked (tracked-files))
(define %tracked-secret-files
  (filter (lambda (path) (string-contains path "/secrets/")) %tracked))

(test-assert "tracked secret inventory contains only encrypted/public material"
             (every (lambda (path)
                      (or (string-suffix? ".age" path)
                          (string-suffix? ".agepub" path)))
                    %tracked-secret-files))

(test-assert "tracked age files use armored age ciphertext"
             (every (lambda (path)
                      (or (not (string-suffix? ".age" path))
                          (string-prefix? "-----BEGIN AGE ENCRYPTED FILE-----"
                                          (read-file path))))
                    %tracked-secret-files))

(test-assert "tracked files contain no private-key markers"
             (every (lambda (path)
                      (or (not (file-exists? path))
                          (let ((content (false-if-exception (read-file path))))
                            (or (not content)
                                (not (any
                                      (lambda (line)
                                        (any (lambda (marker)
                                               (string-prefix? marker line))
                                             %private-key-markers))
                                      (string-split content #\newline)))))))
                    %tracked))

(test-end "repository-hygiene")
