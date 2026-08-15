;;; 基于 Guile spawn（posix_spawn wrapper）的 runtime-safe subprocess
;;; primitives——initrd 的 guile-static 下可用（spawn 是内置过程，
;;; 不依赖 (ice-9 spawn) 模块；实测 guile-static 3.0.11 无该模块）。
;;;
;;; 背景（historical debugging）：TPM 自动解锁早期实现经 Guile 传统
;;; popen/fork 型 subprocess 路径调用 tpm2-tools/cryptsetup，在 static
;;; Guile 的 initrd/PID1 环境中可复现 GC 相关故障（movzbl (%rax)@0x4d5593、
;;; pthread_getattr_np GC Warning，与 tpm2-tools 版本无关）。决定性实验
;;; 证明的是「fork/popen 路径 + static Guile PID1 环境」的组合可复现
;;; 故障，并非 BDW GC 本身不能在 PID1 下运行。最终修复：保留 Guile
;;; PID1 不变，改用 spawn（posix_spawn，父进程不 fork）后故障消失，
;;; 通过多次真实 TPM 自动解锁验证。
;;;
;;; 约定：
;;;   - 全部使用显式绝对路径（#:search-path? #f，initrd 无 PATH 依赖）；
;;;   - 退出码用 status:exit-val（同 project process.scm）；
;;;   - 不创建大型 process framework，只提供本项目需要的四个原语。

(define-module (guixcfg utils spawn)
               #:use-module (rnrs io ports)       ; pipe、port->fdes
               #:use-module (ice-9 rdelim)        ; read-line
               #:use-module (ice-9 popen)         ; OPEN_READ 等
               #:use-module (ice-9 binary-ports)  ; get-bytevector-all
               #:use-module (rnrs bytevectors)    ; bytevector 相关
               #:use-module (srfi srfi-1)          ; take、member
               #:export (spawn-wait
                         spawn-with-stdin
                         spawn-capture
                         spawn-pipeline
                         wait-exit))

;;; ────────────────────────────────────────────────────────────
;;; 内部 helpers

(define* (spawn* program argv #:key (environment #f) (input #f) (output #f))
         "spawn 的薄封装：显式 #:search-path? #f；INPUT/OUTPUT 为 fd 或
#f（继承）。ARGV 是完整 argv（含 argv[0]——guile spawn 的 args 是
完整 argv，不含 argv[0] 时程序会拿到错误的 argv[0]）。
返回子进程 pid。"
         (cond
           ((and environment input output)
            (spawn program argv #:search-path? #f
                   #:environment environment #:input input #:output output))
           ((and environment output)
            (spawn program argv #:search-path? #f
                   #:environment environment #:output output))
           ((and environment input)
            (spawn program argv #:search-path? #f
                   #:environment environment #:input input))
           (environment
            (spawn program argv #:search-path? #f #:environment environment))
           ((and input output)
            (spawn program argv #:search-path? #f #:input input #:output output))
           (output
            (spawn program argv #:search-path? #f #:output output))
           (input
            (spawn program argv #:search-path? #f #:input input))
           (else
            (spawn program argv #:search-path? #f))))

(define (wait-exit pid)
  "等待 PID 并返回退出码；信号终止时返回 128+signal。
用 POSIX wait status 字（低 7 位 = 终止信号，高 8 位 = 退出码）；
guile 3.0.11 无 status:term-signal 访问器（实测）。"
  (let* ((r (waitpid pid))
         (status (cdr r)))
    (if (zero? (logand status #x7f))
      (ash status -8)
      (+ 128 (logand status #x7f)))))

;;; ────────────────────────────────────────────────────────────
;;; 原语

(define* (spawn-wait program . args)
         "spawn PROGRAM 并等待退出，返回退出码（非零 = 失败）。ARGS 是参数
（不含 program 本身，同 invoke 风格）。"
         (let ((pid (spawn* program (cons program args))))
           (wait-exit pid)))

(define* (spawn-with-stdin input program . args)
         "把 INPUT（string 或 bytevector）写入 PROGRAM 的 stdin（经 pipe），
等待退出，返回退出码。INPUT 只存在于本进程内存。"
         (let* ((pair (pipe))
                (pid (spawn* program (cons program args)
                             #:input (car pair))))
           (close-port (car pair))                ; 父进程不写子进程 stdin
           (if (bytevector? input)
             (put-bytevector (cdr pair) input)
             (display input (cdr pair)))
           (close-port (cdr pair))                ; EOF → 子进程 stdin 结束
           (wait-exit pid)))

(define* (spawn-capture program . args)
         "捕获 PROGRAM 的 stdout（bytevector），返回 (values output exit-status)。
OUTPUT 是原始字节（可能含 NUL）。"
         (let* ((pair (pipe))
                (pid (spawn* program (cons program args)
                             #:output (cdr pair))))
           (close-port (cdr pair))                ; 父进程不写子进程 stdout
           (let ((output (get-bytevector-all (car pair))))
             (close-port (car pair))
             (values output (wait-exit pid)))))

(define (split-pipeline-args args)
  "按 -- 分隔符把 ARGS 分成 (producer-args . consumer-args)。"
  (let loop ((l args) (acc '()))
    (cond ((null? l)
           (error "spawn-pipeline: missing -- separator"))
      ((equal? (car l) "--")
       (cons (reverse acc) (cdr l)))
      (else
       (loop (cdr l) (cons (car l) acc))))))

(define* (spawn-pipeline producer . producer+consumer-args)
         "PRODUCER 的 stdout 经 pipe 直接接到 CONSUMER 的 stdin（进程间
FD 直连，明文不经 Scheme heap）。返回 (values producer-status
consumer-status)。父进程只负责 pipe 创建、spawn、关闭未用 FD、
waitpid。
用法：(spawn-pipeline producer producer-arg... -- consumer consumer-arg...)"
         (let* ((parts (split-pipeline-args producer+consumer-args))
                (producer-args (car parts))
                (consumer-args (cdr parts))
                (consumer (car consumer-args))
                (consumer-argv (cons consumer (cdr consumer-args)))
                (pair (pipe))
                (producer-pid (spawn* producer (cons producer producer-args)
                                      #:output (cdr pair)))
                ;; 子进程继承 (cdr pair)；父进程立即关闭写端，consumer 才能
                ;; 在 producer 退出时看到 EOF。
                (consumer-pid (spawn* consumer consumer-argv
                                      #:input (car pair))))
           (close-port (cdr pair))                ; 父进程写端
           (close-port (car pair))                ; 父进程读端（不读）
           (let ((producer-status (wait-exit producer-pid))
                 (consumer-status (wait-exit consumer-pid)))
             (values producer-status consumer-status))))

;;; spawn.scm ends here
