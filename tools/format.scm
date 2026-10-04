;;; Pinned execution entrypoint for repo-wide Scheme formatting.
;;;
;;; Usage (repository root):
;;;   guix time-machine -C channels.lock.scm -- repl tools/format.scm -- MODE [FILE...]
;;; MODE is `run` (format in place) or `check` (list files that would
;;; change; exit 1 when any).  FILE arguments restrict the run; the
;;; default is every *.scm under modules/, tests/, tools/ and templates/
;;; plus the top-level blueprint.scm.
;;;
;;; Formatting authority is pinned Guix's `guix style --whole-file'
;;; ((guix scripts style), the pure-Guile pretty-print-with-comments
;;; pipeline that replaced etc/indent-code.el upstream in 2022).
;;; check mode reproduces format-whole-file's read/print pipeline
;;; without writing (upstream's --dry-run flag does not apply to
;;; whole-file mode).

(use-modules (guix read-print)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define %scan-roots
  '("modules" "tests" "tools" "templates"))
;; blueprint.scm 不在默认范围：它用 bluebox DSL 的 #% 前缀记号，
;; (guix read-print) 的 reader 无法解析（read-error "#%")。
(define %extra-files
  '())

(define (collect-files)
  "Return all in-scope .scm files (relative paths), sorted."
  (define (enter? name stat result)
    #t)
  (define (leaf name stat result)
    (if (string-suffix? ".scm" name)
        (cons name result) result))
  (define (nop name stat result)
    result)
  (sort (append (append-map (lambda (root)
                              (if (file-exists? root)
                                  (file-system-fold enter?
                                                    leaf
                                                    nop
                                                    nop
                                                    nop
                                                    nop
                                                    '()
                                                    root)
                                  '())) %scan-roots)
                (filter file-exists? %extra-files)) string<?))

;;; Same read/print pipeline as (guix scripts style) format-whole-file,
;;; minus the write.
(define (formatted-content file)
  (call-with-output-string (lambda (port)
                             (pretty-print-with-comments/splice port
                              (call-with-input-file file
                                read-with-comments/sequence
                                #:guess-encoding #t)
                              #:format-comment canonicalize-comment
                              #:format-vertical-space
                              canonicalize-vertical-space))))

(define (check-files files)
  "Print FILES whose content differs from the formatted form; return the
number of such files."
  (let loop
    ((files files)
     (stale 0))
    (match files
      (() stale)
      ((file . rest) (let ((orig (call-with-input-file file
                                   get-string-all))
                           (new (formatted-content file)))
                       (if (string=? orig new)
                           (loop rest stale)
                           (begin
                             (format #t "would reformat: ~a~%" file)
                             (loop rest
                                   (1+ stale)))))))))

(define (run-files files)
  (let ((guix-style (module-ref (resolve-module '(guix scripts style))
                                'guix-style)))
    (for-each (lambda (file)
                (guix-style "--whole-file" file)
                (format #t "formatted: ~a~%" file)) files)))

(define (usage)
  (format (current-error-port) "usage: format.scm -- (run|check) [FILE...]~%")
  (exit 1))

(let ((args (cdr (command-line))))
  (when (and (pair? args)
             (string=? (car args) "--"))
    (set! args
          (cdr args)))
  (match args
    ((mode . files) (let ((files (if (null? files)
                                     (collect-files) files)))
                      (cond
                        ((string=? mode "run")
                         (when (zero? (getuid))
                           (format (current-error-port)
                            "format: refusing to run as root (rewritten files would become root-owned).~%")
                           (exit 1))
                         (run-files files))
                        ((string=? mode "check")
                         (let ((stale (check-files files)))
                           (if (zero? stale)
                               (format #t
                                       "all ~a files are guix-style clean~%"
                                       (length files))
                               (begin
                                 (format (current-error-port)
                                         "~a file(s) need formatting~%" stale)
                                 (exit 1)))))
                        (else (usage)))))
    (_ (usage))))
