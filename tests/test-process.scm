;;; utils/process.scm 的单元测试。由 tests/run-tests.scm 加载运行。
;;; 覆盖：stdin 注入（文本/二进制）、stdout 捕获（文本/二进制）、
;;; 含 #x00 的二进制数据不截断、非零退出码报错、子进程提前退出
;;; （EPIPE）不悬挂。

(use-modules (guixcfg utils process)
             (ice-9 binary-ports)   ; get-bytevector-all
             (rnrs bytevectors)     ; make-bytevector
             (srfi srfi-64))

(test-begin "process")

(define %tmp-dir
  (string-append "/tmp/guixcfg-test-process-"
                 (number->string (getpid))))
(mkdir %tmp-dir)

(dynamic-wind
 (const #t)
 (lambda ()
   ;; ── stdin 注入 ───────────────────────────────────────────
   (let ((f (string-append %tmp-dir "/stdin.txt")))
     (invoke-with-stdin "hello passphrase" "sh" "-c"
                        (string-append "cat > " f))
     (test-equal "text stdin passed to child correctly"
                 "hello passphrase"
                 (call-with-input-file f get-string-all)))
   
   (let ((f (string-append %tmp-dir "/stdin.bin")))
     (invoke-with-bytevector-stdin #vu8(1 0 2 255 0 65) "sh" "-c"
                                   (string-append "cat > " f))
     (test-equal "binary stdin with #x00 not truncated"
                 #vu8(1 0 2 255 0 65)
                 (call-with-input-file f get-bytevector-all)))
   
   ;; ── stdout 捕获 ──────────────────────────────────────────
   (test-equal "text stdout captured"
               "hello"
               (invoke-capture "printf" "hello"))
   
   (test-equal "binary stdout with #x00 not truncated"
               #vu8(97 0 98)
               (invoke-capture-bytevector "printf" "a\\000b"))
   
   (test-equal "binary stdout high bytes pass through without encoding"
               #vu8(255 254 253)
               (invoke-capture-bytevector "printf" "\\377\\376\\375"))
   
   ;; ── 退出码 ───────────────────────────────────────────────
   (test-error "capture mode errors on non-zero exit" #t
               (invoke-capture "sh" "-c" "printf partial; exit 3"))
   (test-error "stdin inject mode errors on non-zero exit" #t
               (invoke-with-stdin "x" "sh" "-c" "exit 3"))
   (test-error "binary stdin inject errors on non-zero exit" #t
               (invoke-with-bytevector-stdin #vu8(1) "sh" "-c" "exit 1"))
   
   ;; 子进程提前退出（不读 stdin）时写端 EPIPE：不悬挂、不误报
   (test-assert "child exiting early (EPIPE) returns normally"
                (begin
                 (invoke-with-stdin (make-string 200000 #\a)
                                    "sh" "-c" "exit 0")
                 #t))
   (test-assert "binary EPIPE returns normally"
                (begin
                 (invoke-with-bytevector-stdin
                  (make-bytevector 200000 1)
                  "sh" "-c" "exit 0")
                 #t)))
 (lambda ()
   (false-if-exception (delete-file-recursively %tmp-dir))))

(test-end)
