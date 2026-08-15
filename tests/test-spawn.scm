;;; spawn primitive 的单元/集成测试（Phase 5）：
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

;; 1. producer → pipe → consumer（FD 直连，退出码 0/0）
(let-values (((ps cs) (spawn-pipeline "/bin/echo" "hello-pipe"
                                      "--" "/bin/cat" "-")))
            (test-equal "pipeline: producer 退出码 0" 0 ps)
            (test-equal "pipeline: consumer 退出码 0" 0 cs))

;; 2. binary data 含 NUL（spawn-capture 原始字节）
(let-values (((out st) (spawn-capture "/usr/bin/printf" "a\\0b\\0c")))
            (test-equal "binary capture: 退出码 0" 0 st)
            (test-equal "binary capture: 含 NUL 的字节"
                        #vu8(97 0 98 0 99) out))

;; 3. producer exit != 0（consumer 收到 EOF）
(let-values (((ps cs) (spawn-pipeline "/bin/false"
                                      "--" "/bin/cat" "-")))
            (test-assert "producer 非零退出码" (not (zero? ps)))
            (test-equal "consumer 在 producer 失败后正常退出" 0 cs))

;; 4. consumer exit != 0
(let-values (((ps cs) (spawn-pipeline "/bin/echo" "x"
                                      "--" "/bin/false")))
            (test-equal "producer 正常" 0 ps)
            (test-assert "consumer 非零退出码" (not (zero? cs))))

;; 5. consumer early close（producer 写 EPIPE，非零/信号退出）
(let-values (((ps cs) (spawn-pipeline "/bin/sh" "-c" "head -c 100000 /dev/zero"
                                      "--" "/bin/head" "-c" "1")))
            (test-equal "early close: consumer 退出码 0" 0 cs)
            (test-assert "early close: producer 因 EPIPE 非零" (not (zero? ps))))

;; 6. exec target 不存在（spawn 抛错）
(test-assert "exec target 不存在 → 抛错"
             (catch #t
               (lambda ()
                 (spawn-wait "/nonexistent/binary")
                 #f)
               (lambda (k . a) #t)))

;; 7. stderr 可正确处理（默认继承：退出码反映命令）
(let ((st (spawn-wait "/bin/sh" "-c" "echo err >&2; exit 3")))
  (test-equal "stderr 默认继承 + 退出码 3" 3 st))

;; 8. no zombie（wait-exit 后子进程已回收；再次 waitpid 报 ECHILD）
(let* ((pid (spawn "/bin/true" '("/bin/true")))
       (st (wait-exit pid)))
  (test-equal "wait-exit 退出码 0" 0 st)
  (test-equal "waitpid 已回收（无 zombie）"
              #f
              (catch 'system-error
                (lambda ()
                  (let ((r (waitpid pid)))
                    (and (pair? r) (eq? (car r) pid))))
                (lambda (k . a) #f))))

;; 9. no leaked FD（spawn 前后 fd 数不变）
(define (fd-count)
  (length (or (scandir "/proc/self/fd") '())))
(let ((before (fd-count)))
  (spawn-wait "/bin/true")
  (spawn-capture "/bin/echo" "x")
  (let-values (((ps cs) (spawn-pipeline "/bin/echo" "x"
                                        "--" "/bin/cat" "-")))
              (values ps cs))
  (test-equal "spawn 前后 fd 数不变" before (fd-count)))

(test-end)
