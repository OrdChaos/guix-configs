;;; 运行时 UI 语言策略回归：guix-config 自己产生的、面向 tty/console/CLI
;;; 的 runtime 消息必须为英文（早期启动与 Linux 虚拟控制台不能假定存在
;;; CJK 字体）。注释、docstring、测试描述仍允许中文。
;;;
;;; 检查范围：modules/ 与 tools/ 下 .scm 中 format / error / display /
;;; invoke 调用的字符串字面量不得含 Han 字符（U+4E00–U+9FFF）。

(use-modules (ice-9 ftw)
             (ice-9 regex)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (han? ch)
  (let ((n (char->integer ch)))
    (and (>= n #x4e00) (<= n #x9fff))))

(define (string-has-han? s)
  (let loop ((i 0))
    (and (< i (string-length s))
         (or (han? (string-ref s i)) (loop (+ i 1))))))

(define (runtime-string-call? line)
  "行内是否出现 runtime 输出调用（format/error/display/invoke）。"
  (let ((m (string-match "\\((format|error|display|invoke)\\b" line)))
    (and m (not (string-contains line ";;")))))

(define (extract-string-literals line)
  "提取行内的双引号字符串字面量（Han 检测用 char 级——POSIX regex
不支持 \\u 范围）。"
  (let loop ((i 0) (acc '()))
    (let ((m (string-match "\"([^\"]*)\"" line i)))
      (if m
        (loop (match:end m) (cons (match:substring m 1) acc))
        (reverse acc)))))

(define (scan-file path)
  "返回 PATH 中的违规列表：((行号 . 字符串) ...)。"
  (let loop ((lines (call-with-input-file path
                                          (lambda (p)
                                            (let l ((acc '()) (i 1))
                                              (let ((line (read-line p)))
                                                (if (eof-object? line)
                                                  (reverse acc)
                                                  (l (cons (cons i line) acc) (+ i 1))))))))
             (acc '()))
    (if (null? lines)
      (reverse acc)
      (let* ((line (cdar lines))
             (viol (if (and (runtime-string-call? line)
                            (not (string-prefix? ";;" line)))
                     (filter string-has-han?
                             (extract-string-literals line))
                     '())))
        (loop (cdr lines)
              (append (map (lambda (s) (cons (caar lines) s)) viol) acc))))))

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

(define (runtime-han-violations)
  "扫描 modules/ 与 tools/：返回违规列表（(file line string) ...）。"
  (append-map
   (lambda (f)
     (map (lambda (v) (cons f v)) (scan-file f)))
   (append (scm-files (string-append (getcwd) "/modules"))
           (scm-files (string-append (getcwd) "/tools")))))

(test-begin "ui-language")

(test-assert "production runtime strings contain no Han characters"
             (let ((viol (runtime-han-violations)))
               (for-each (lambda (v)
                           (format #t "  Han runtime string: ~a:~a ~s~%"
                                   (car v) (caadr v) (cdadr v)))
                         viol)
               (null? viol)))

(test-end "ui-language")
