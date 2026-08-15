;;; Guix Home stale pivot 的保守清理 CLI（tools/reconfigure.sh 调用）。
;;; 用法：
;;;   guile -L modules -s tools/home-pivot.scm --check PATH
;;;   guile -L modules -s tools/home-pivot.scm --clean PATH
;;; --check 打印 disposition；unsafe 时 exit 1。
;;; --clean 仅清理 safe-stale-pivot（symlink 指向 store home）；unsafe
;;; 时报错 exit 2 并保留文件。

(use-modules (guixcfg home pivot)
             (ice-9 match))

(define (usage)
  (display "usage: home-pivot.scm --check|--clean PATH\n" (current-error-port))
  (exit 64))

(define (main args)
  (match (cdr args)
    (((or "--check" "--clean") path)
     (let* ((clean? (string=? (cadr args) "--clean"))
            (d (if clean?
                   (remove-stale-pivot! path)
                   (stale-pivot-disposition path))))
       (display d) (newline)
       (exit (if (eq? d 'unsafe) (if clean? 2 1) 0))))
    (_ (usage))))

(main (command-line))
