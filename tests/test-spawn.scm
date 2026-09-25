;;; spawn primitive 的单元/集成测试：
;;;   1. producer → pipe → consumer
;;;   2. binary data 含 NUL
;;;   3. producer exit != 0
;;;   4. consumer exit != 0
;;;   5. consumer early close
;;;   6. exec target 不存在
;;;   7. stderr 可正确处理
;;;   8. no zombie
;;;   9. no leaked FD
;;; 本测试同时可在 guile-static-initrd 的 Guile 下运行（spawn 路径
;;; 不 segfault 的回归证明）。

(use-modules (guixcfg utils spawn)
             (rnrs bytevectors)
             (ice-9 rdelim)
             (ice-9 ftw)                ; scandir
             (srfi srfi-11)              ; let-values
             (srfi srfi-64))

(test-begin "spawn")

;; spawn 刻意要求显式绝对路径（#:search-path? #f）；测试环境是 Guix，
;; 无 FHS /bin。从受控 PATH 解析宿主提供的 coreutils/sh 绝对路径，
;; 再以其验证 spawn 语义——不依赖 /bin 存在。
(define (tool name)
  (or (search-path (string-split (or (getenv "PATH") "") #\:) name)
      (error "required test executable is absent from PATH" name)))

(define %cat (tool "cat"))
(define %echo (tool "echo"))
(define %false (tool "false"))
(define %head (tool "head"))
(define %printf (tool "printf"))
(define %sh (tool "sh"))
(define %true (tool "true"))

;; 1. producer → pipe → consumer（FD 直连，退出码 0/0）
(let-values (((ps cs) (spawn-pipeline %echo "hello-pipe"
                                      "--" %cat "-")))
            (test-equal "pipeline: producer exit 0" 0 ps)
            (test-equal "pipeline: consumer exit 0" 0 cs))

;; 2. binary data 含 NUL（spawn-capture 原始字节）
(let-values (((out st) (spawn-capture %printf "a\\0b\\0c")))
            (test-equal "binary capture: exit 0" 0 st)
            (test-equal "binary capture: bytes with NUL"
                        #vu8(97 0 98 0 99) out))

;; 3. producer exit != 0（consumer 收到 EOF）
(let-values (((ps cs) (spawn-pipeline %false
                                      "--" %cat "-")))
            (test-assert "producer non-zero exit" (not (zero? ps)))
            (test-equal "consumer exits normally after producer failure" 0 cs))

;; 4. consumer exit != 0
;; 注意：consumer 不能用 /bin/false（不读 stdin 立即退出）——producer
;; 的 write 与 consumer 的 exit 存在竞态（EPIPE），退出码不稳定。用
;; “读光 stdin 再非零退出”的 consumer，确定性验证 producer 不受影响。
(let-values (((ps cs) (spawn-pipeline %echo "x"
                                      "--" %sh "-c"
                                      "cat > /dev/null; exit 1")))
            (test-equal "producer normal" 0 ps)
            (test-assert "consumer non-zero exit" (not (zero? cs))))

;; 5. consumer early close（producer 写 EPIPE，非零/信号退出）
(let-values (((ps cs) (spawn-pipeline %sh "-c" "head -c 100000 /dev/zero"
                                      "--" %head "-c" "1")))
            (test-equal "early close: consumer exit 0" 0 cs)
            (test-assert "early close: producer non-zero due to EPIPE" (not (zero? ps))))

;; 6. exec target 不存在（spawn 抛错）
(test-assert "missing exec target -> throws"
             (catch #t
               (lambda ()
                 (spawn-wait "/nonexistent/binary")
                 #f)
               (lambda (k . a) #t)))

;; 7. stderr 可正确处理（默认继承：退出码反映命令）
(let ((st (spawn-wait %sh "-c" "echo err >&2; exit 3")))
  (test-equal "stderr inherited by default + exit 3" 3 st))

;; 8. no zombie（wait-exit 后子进程已回收；再次 waitpid 报 ECHILD）
(let* ((pid (spawn %true (list %true)))
       (st (wait-exit pid)))
  (test-equal "wait-exit exit 0" 0 st)
  (test-equal "waitpid reaped (no zombie)"
              #f
              (catch 'system-error
                (lambda ()
                  (let ((r (waitpid pid)))
                    (and (pair? r) (eq? (car r) pid))))
                (lambda (k . a) #f))))

;; 9. no leaked FD（fd count unchanged across spawn）
(define (fd-count)
  (length (or (scandir "/proc/self/fd") '())))
(let ((before (fd-count)))
  (spawn-wait %true)
  (spawn-capture %echo "x")
  (let-values (((ps cs) (spawn-pipeline %echo "x"
                                        "--" %cat "-")))
              (values ps cs))
  (test-equal "fd count unchanged across spawn" before (fd-count)))

(test-end)
