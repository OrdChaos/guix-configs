;;; 运行时 UI 语言策略回归：guix-config 自己产生的、面向 tty/console/CLI
;;; 的 runtime 消息必须为 English printable ASCII（早期启动与 Linux
;;; 虚拟控制台不能假定存在 CJK 字体）。注释、docstring、测试数据
;;; （如非 ASCII passphrase 样本）仍允许中文。
;;;
;;; 静态检查范围：
;;;   - modules/ 与 tools/ 下 .scm 中 runtime 输出调用（format / error /
;;;     display / invoke / throw / scm-error / plan summary / usage）的
;;;     字符串字面量不得含非 ASCII 字符；
;;;   - tests/ 下 .scm 的测试断言描述（test-assert 等宏的首参）同理；
;;;   - tools/ 与 tests/integration/t3/ 下 .sh 的 echo/printf 字符串、
;;;     ${VAR:?} 错误消息与 heredoc 输出内容同理。
;;;
;;; 动态 smoke：真实执行工具（guix repl）并断言其 CLI 输出为
;;; printable ASCII（usage、plan、错误路径；只读、无副作用命令）。

(use-modules (ice-9 ftw)
             (ice-9 regex)
             (ice-9 rdelim)
             (ice-9 textual-ports)  ; get-string-all
             (ice-9 popen)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (non-ascii? ch)
  (> (char->integer ch) 127))

(define (string-has-non-ascii? s)
  (let loop ((i 0))
    (and (< i (string-length s))
         (or (non-ascii? (string-ref s i)) (loop (+ i 1))))))

(define (read-file-lines path)
  "读取 PATH 全部行（含行尾）为列表。"
  (call-with-input-file path
    (lambda (p)
      (let loop ((acc '()))
        (let ((line (read-line p)))
          (if (eof-object? line)
            (reverse acc)
            (loop (cons line acc))))))))

(define (extract-string-literals line)
  "提取行内的双引号字符串字面量列表。"
  (let loop ((i 0) (acc '()))
    (let ((m (string-match "\"([^\"]*)\"" line i)))
      (if m
        (loop (match:end m) (cons (match:substring m 1) acc))
        (reverse acc)))))

(define (strip-comment line comment-char)
  "去掉引号外 COMMENT-CHAR 起至行尾的注释，返回剩余部分。
转义引号（\\\"）不会提前结束字符串。"
  (let loop ((i 0) (in-str #f))
    (if (>= i (string-length line))
      line
      (let ((c (string-ref line i)))
        (cond
         (in-str
          (cond ((char=? c #\\) (loop (+ i 2) #t))
                ((char=? c #\") (loop (+ i 1) #f))
                (else (loop (+ i 1) #t))))
         ((char=? c #\") (loop (+ i 1) #t))
         ((char=? c comment-char) (substring line 0 i))
         (else (loop (+ i 1) #f)))))))

(define (scan-lines lines pred)
  "对 LINES（(行号 . 行) 列表）中满足 PRED 的行提取字符串字面量，
返回违规列表：(行号 . 字符串)。PRED 接收去掉注释后的行。"
  (append-map
   (lambda (pair)
     (let* ((n (car pair))
            (line (cdr pair))
            (stripped (strip-comment line #\;)))
       (if (pred stripped)
         (map (lambda (s) (cons n s))
              (filter string-has-non-ascii? (extract-string-literals stripped)))
         '())))
   lines))

(define (numbered-lines path)
  "读取 PATH 为 (行号 . 行) 列表。"
  (let loop ((lines (read-file-lines path)) (acc '()) (n 1))
    (if (null? lines)
      (reverse acc)
      (loop (cdr lines) (cons (cons n (car lines)) acc) (+ n 1)))))

(define (scm-files dir)
  "递归收集 DIR 下的 .scm 文件（绝对路径）。"
  (append-map
   (lambda (e)
     (if (or (string=? e ".") (string=? e ".."))
       '()
       (let ((p (string-append dir "/" e)))
         (if (eq? (stat:type (stat p)) 'directory)
           (scm-files p)
           (if (string-suffix? ".scm" e) (list p) '())))))
   (scandir dir)))

;;; ────────────────────────────────────────────────────────────
;;; 静态扫描

(define (scan-scheme-runtime dir)
  "扫描 DIR 下 .scm：runtime 输出调用行的字符串字面量。
调用包括 format/error/display/invoke/throw/scm-error、plan summary、
usage 帮助文本。"
  (append-map
   (lambda (f)
     (let ((pred
            (lambda (stripped)
              (let ((m (string-match
                        "\\((format|error|display|invoke|throw|scm-error|summary|usage)\\b"
                        stripped)))
                (and m #t)))))
       (map (lambda (v) (cons f v)) (scan-lines (numbered-lines f) pred))))
   (append (scm-files (string-append (getcwd) "/modules"))
           (scm-files (string-append (getcwd) "/tools")))))

(define (scan-test-descriptions dir)
  "扫描 DIR 下 .scm：test-assert 等断言宏行内的字符串字面量
（断言描述是 guix test 的运行时输出）。"
  (append-map
   (lambda (f)
     (let ((pred
            (lambda (stripped)
              (let ((m (string-match
                        "\\((test-(assert|error|group|equal|eq|eql))\\b"
                        stripped)))
                (and m #t)))))
       (map (lambda (v) (cons f v)) (scan-lines (numbered-lines f) pred))))
   (filter (lambda (f) (not (string-suffix? "test-ui-language.scm" f)))
           (scm-files (string-append (getcwd) "/tests")))))

(define (scan-shell-output dirs)
  "扫描 .sh：echo/printf 字符串、${VAR:?} 错误消息与 heredoc 输出内容。
只读脚本（tools/test-*.sh、tests/integration/t3/*.sh）。"
  (append-map
   (lambda (dir)
     (let ((files (filter (lambda (f) (string-suffix? ".sh" f))
                          (scandir dir))))
       (append-map
        (lambda (name)
          (let ((path (string-append dir "/" name)))
            (let loop ((lines (numbered-lines path)) (heredoc #f) (acc '()))
              (if (null? lines)
                (map (lambda (v) (cons path v)) (reverse acc))
                (let* ((n (caar lines))
                       (line (cdar lines))
                       (plain (strip-comment line #\#)))
                  (cond
                   (heredoc
                    (let ((end? (string=? (string-trim-right line) heredoc)))
                      (loop (cdr lines)
                            (and (not end?) heredoc)
                            (if (and (not end?) (string-has-non-ascii? line))
                              (cons (cons n line) acc)
                              acc))))
                   ((string-match "<<(-?)[[:space:]]*'?([A-Za-z_][A-Za-z0-9_]*)" line)
                    => (lambda (m)
                         (loop (cdr lines) (match:substring m 2) acc)))
                   ((or (string-match "^[[:space:]]*(echo|printf)\\b" plain)
                        (string-match "\\$\\{[^}]*:\\?[^}]*\\}" plain))
                    (loop (cdr lines) #f
                          (append (map (lambda (s) (cons n s))
                                       (filter string-has-non-ascii?
                                               (extract-string-literals plain)))
                                  acc)))
                   (else (loop (cdr lines) #f acc))))))))
        files)))
   dirs))

;;; ────────────────────────────────────────────────────────────
;;; 动态 smoke：只读、无副作用的 CLI 执行

(define (run-captured . args)
  "以 guix repl 运行 ARGS（工具相对路径 + 可选 -- 子命令），
捕获合并 stdout/stderr，返回 (values 输出 退出码)。"
  (let* ((tmp (string-append "/tmp/guixcfg-ui-scan-"
                             (number->string (getpid))))
         (cmd (string-append
               (string-join
                (map (lambda (a) (string-append "'" a "'"))
                     (cons "guix" args))
                " ")
               " > " tmp " 2>&1"))
         (code (status:exit-val (system cmd))))
    (let ((out (call-with-input-file tmp get-string-all)))
      (delete-file tmp)
      (values out code))))

(define (violations->text viol)
  "违规列表 → 可读文本（无违规时返回空串）。"
  (string-join
   (map (lambda (v)
          (format #f "  ~a:~a ~s" (car v) (cadr v) (cddr v)))
        viol)
   "\n"))

;;; ────────────────────────────────────────────────────────────


(test-begin "ui-language")

(test-assert "production runtime strings contain no non-ASCII"
             (let ((viol (scan-scheme-runtime
                          (string-append (getcwd)))))
               (format #t "~a" (violations->text viol))
               (null? viol)))

(test-assert "test assertion descriptions contain no non-ASCII"
             (let ((viol (scan-test-descriptions
                          (string-append (getcwd)))))
               (format #t "~a" (violations->text viol))
               (null? viol)))

(test-assert "shell runtime output contains no non-ASCII"
             (let ((viol (scan-shell-output
                          (list (string-append (getcwd) "/tools")
                                (string-append (getcwd)
                                               "/tests/integration/t3")))))
               (format #t "viol-count=~a~%" (length viol))
               (for-each (lambda (v)
                           (format #t "  ~a:~a ~s~%" (car v) (cadr v) (cddr v)))
                         viol)
               (null? viol)))

(test-assert "disk-install usage output is printable ASCII"
             (call-with-values
                 (lambda () (run-captured "repl" "tools/disk-install.scm"))
               (lambda (out code)
                 (format #t "exit=~a~%~a~%" code out)
                 (and (not (string-has-non-ascii? out))
                      (string-contains out "Usage:")
                      (string-contains out "commit-root")))))

(test-assert "disk-install plan output is printable ASCII"
             (call-with-values
                 (lambda ()
                   (run-captured "repl" "tools/disk-install.scm"
                                 "--" "plan" "vm" "/dev/vda"))
               (lambda (out code)
                 (format #t "exit=~a~%" code)
                 (and (zero? code)
                      (not (string-has-non-ascii? out))
                      (string-contains out "Disk ready for guix system init")))))

(test-assert "tpm2-enroll usage output is printable ASCII"
             (call-with-values
                 (lambda () (run-captured "repl" "tools/tpm2-enroll.scm"))
               (lambda (out code)
                 (format #t "exit=~a~%" code)
                 (and (not (string-has-non-ascii? out))
                      (string-contains out "Usage:")))))

(test-assert "secure-boot-enroll error path is printable ASCII"
             (call-with-values
                 (lambda () (run-captured "repl" "tools/secure-boot-enroll.scm"))
               (lambda (out code)
                 (format #t "exit=~a~%" code)
                 (and (not (zero? code))
                      (not (string-has-non-ascii? out))
                      (string-contains out "key set is incomplete")))))

(test-end "ui-language")
