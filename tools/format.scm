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
             (ice-9 regex)             ; string-match
             (srfi srfi-1)
             (srfi srfi-11))           ; let-values

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

;;; 已知不安全输入（2026-10-04 实证）：(guix read-print) 对 cdr 位置是
;;; unquote 的 dotted pair 不保真——`(X . ,Y)' 会被打印成
;;; `(X unquote Y)'（丢点、值不再求值，曾损坏 install/gtk 等 16 个
;;; 文件的 128 处 quasiquote，修复见 git 历史）。含 `. ,'（含跨行
;;; 变体）的文件在上游修复前一律跳过；read-print pipeline 读不了的
;;; 文件（如 bluebox 的 #% DSL）也跳过。跳过永远安全，只是不排版。
(define (dotted-unquote-source? text)
  "TEXT 含可疑的 dotted-pair + unquote 结构（`. ,` 或点号行尾换行后
接逗号）。"
  (or (string-contains text ". ,")
      (string-match "\\.[ \t]*\n[ \t]*," text)))

(define (read-print-loadable? file)
  "文件能否被 (guix read-print) 的 reader 完整读取。"
  (catch #t
    (lambda ()
      (call-with-input-file file read-with-comments/sequence
                            #:guess-encoding #t)
      #t)
    (lambda _ #f)))

(define (skip-reason file)
  "返回跳过原因字符串；可安全格式化则返回 #f。"
  (let ((text (call-with-input-file file get-string-all)))
    (cond ((dotted-unquote-source? text)
           "contains dotted-pair + unquote (upstream read-print fidelity bug)")
          ((not (read-print-loadable? file))
           "not readable by (guix read-print)")
          (else #f))))

(define (partition-files files)
  "FILES → (values 可格式化 跳过数)；跳过的文件逐个告警。"
  (let loop ((files files) (safe '()) (skipped 0))
    (match files
      (() (values (reverse safe) skipped))
      ((file . rest)
       (let ((reason (skip-reason file)))
         (if reason
             (begin
               (format (current-error-port) "skip: ~a (~a)~%" file reason)
               (loop rest safe (1+ skipped)))
             (loop rest (cons file safe) skipped)))))))

(define (check-files files)
  "打印 FILES 中与格式化结果不一致者；返回 (values 不一致数 跳过数)。"
  (let-values (((safe skipped) (partition-files files)))
    (let loop ((files safe) (stale 0))
      (match files
        (() (values stale skipped))
        ((file . rest) (let ((orig (call-with-input-file file
                                    get-string-all))
                             (new (formatted-content file)))
                         (if (string=? orig new)
                             (loop rest stale)
                             (begin
                               (format #t "would reformat: ~a~%" file)
                               (loop rest
                                     (1+ stale))))))))))

(define (run-files files)
  (let ((guix-style (module-ref (resolve-module '(guix scripts style))
                                'guix-style)))
    (let-values (((safe skipped) (partition-files files)))
      (for-each (lambda (file)
                  (guix-style "--whole-file" file)
                  (format #t "formatted: ~a~%" file)) safe)
      (when (> skipped 0)
        (format (current-error-port) "~a file(s) skipped~%" skipped)))))

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
                         (let-values (((stale skipped)
                                       (check-files files)))
                           (when (> skipped 0)
                             (format (current-error-port)
                                     "~a file(s) skipped~%" skipped))
                           (if (zero? stale)
                               (format #t
                                       "all ~a files are guix-style clean~%"
                                       (- (length files) skipped))
                               (begin
                                 (format (current-error-port)
                                         "~a file(s) need formatting~%" stale)
                                 (exit 1)))))
                        (else (usage)))))
    (_ (usage))))
