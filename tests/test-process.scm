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
     (test-equal "文本 stdin 正确传入子进程"
                 "hello passphrase"
                 (call-with-input-file f get-string-all)))
   
   (let ((f (string-append %tmp-dir "/stdin.bin")))
     (invoke-with-bytevector-stdin #vu8(1 0 2 255 0 65) "sh" "-c"
                                   (string-append "cat > " f))
     (test-equal "二进制 stdin 含 #x00 不截断"
                 #vu8(1 0 2 255 0 65)
                 (call-with-input-file f get-bytevector-all)))
   
   ;; ── stdout 捕获 ──────────────────────────────────────────
   (test-equal "文本 stdout 捕获"
               "hello"
               (invoke-capture "printf" "hello"))
   
   (test-equal "二进制 stdout 含 #x00 不截断"
               #vu8(97 0 98)
               (invoke-capture-bytevector "printf" "a\\000b"))
   
   (test-equal "二进制 stdout 含高位字节不做编码转换"
               #vu8(255 254 253)
               (invoke-capture-bytevector "printf" "\\377\\376\\375"))
   
   ;; ── 退出码 ───────────────────────────────────────────────
   (test-error "捕获模式非零退出码报错" #t
               (invoke-capture "sh" "-c" "printf partial; exit 3"))
   (test-error "stdin 注入模式非零退出码报错" #t
               (invoke-with-stdin "x" "sh" "-c" "exit 3"))
   (test-error "二进制 stdin 注入非零退出码报错" #t
               (invoke-with-bytevector-stdin #vu8(1) "sh" "-c" "exit 1"))
   
   ;; 子进程提前退出（不读 stdin）时写端 EPIPE：不悬挂、不误报
   (test-assert "子进程提前退出（EPIPE）正常返回"
                (begin
                 (invoke-with-stdin (make-string 200000 #\a)
                                    "sh" "-c" "exit 0")
                 #t))
   (test-assert "二进制 EPIPE 正常返回"
                (begin
                 (invoke-with-bytevector-stdin
                  (make-bytevector 200000 1)
                  "sh" "-c" "exit 0")
                 #t)))
 (lambda ()
   (false-if-exception (delete-file-recursively %tmp-dir))))

(test-end)
