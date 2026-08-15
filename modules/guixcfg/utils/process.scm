;;; 进程执行辅助：把数据经 stdin 传给子进程、或捕获子进程 stdout。
;;; 与 (guix build utils) 的 invoke 互补：invoke 继承父进程 stdin，
;;; 这里显式提供 stdin 内容（LUKS passphrase、TPM credential——
;;; 不落盘、不进 argv、不进 environment）；捕获模式用于读取
;;; tpm2-tools 等命令的 stdout 输出。
;;;
;;; API 分文本与二进制两组：
;;;   invoke-with-stdin / invoke-capture       文本（passphrase 等）
;;;   invoke-with-bytevector-stdin / invoke-capture-bytevector
;;;                                            任意字节（TPM random
;;;                                           credential、sealed blob），
;;;                                           不做 UTF-8/string 转换
;;;
;;; 实现说明（相对旧实现 d832ef4 的修正）：
;;;   - 旧 invoke-with-stdin 用 display 写字符串，隐式走端口编码；
;;;     二进制数据必须走 put-bytevector，这里显式分成两组 API；
;;;   - 所有 helper 经 open-pipe* + execvp 直接执行程序，不经过 shell；
;;;   - 子进程提前退出（写端 EPIPE）时仍尝试 close-pipe 取真实状态；
;;;   - 捕获模式在非零退出码时抛错，绝不返回部分输出。

(define-module (guixcfg utils process)
               #:use-module (ice-9 popen)         ; open-pipe*、close-pipe
               #:use-module (ice-9 rdelim)        ; read-string
               #:use-module (ice-9 binary-ports)  ; get-bytevector-all
               #:use-module (rnrs bytevectors)    ; put-bytevector
               #:use-module (srfi srfi-34)        ; guard
               #:export (invoke-with-stdin
                         invoke-with-bytevector-stdin
                         invoke-capture
                         invoke-capture-bytevector))

;;; ────────────────────────────────────────────────────────────
;;; stdin 注入

(define (invoke-with-stdin input program . args)
  "把文本 INPUT 通过管道写入 PROGRAM 的 stdin 并等待退出；
非零退出码抛错。INPUT 只存在于本进程内存。"
  (let ((port (apply open-pipe* OPEN_WRITE program args)))
    (let ((status (guard (e (#t (or (false-if-exception (close-pipe port))
                                    (raise e))))
                         (display input port)
                         (close-pipe port))))
      (unless (zero? (status:exit-val status))
        (error "command failed" program (status:exit-val status))))))

(define (invoke-with-bytevector-stdin input program . args)
  "把字节串 INPUT（bytevector）通过管道写入 PROGRAM 的 stdin 并等待
退出；非零退出码抛错。不做任何字符编码转换（可含 #x00）。
注：写端 EPIPE 在 put-bytevector 下以 raise-exception 风格的
compound exception 抛出（不同于 display 的 throw 风格），必须用
guard 而不是 catch 捕获。"
  (let ((port (apply open-pipe* OPEN_WRITE program args)))
    (let ((status (guard (e (#t (or (false-if-exception (close-pipe port))
                                    (raise e))))
                         (put-bytevector port input)
                         (close-pipe port))))
      (unless (zero? (status:exit-val status))
        (error "command failed" program (status:exit-val status))))))

;;; ────────────────────────────────────────────────────────────
;;; stdout 捕获

(define (invoke-capture program . args)
  "运行 PROGRAM，捕获其 stdout 返回（文本）；非零退出码抛错。
注意不能用 system*/invoke + with-output-to-string 捕获：system* 直接
继承进程 fd 1，不经过 Guile 的 current-output-port。"
  (let ((port (apply open-pipe* OPEN_READ program args)))
    (let ((output (read-string port)))
      (let ((status (close-pipe port)))
        (unless (zero? (status:exit-val status))
          (error "command failed" program (status:exit-val status)))
        output))))

(define (invoke-capture-bytevector program . args)
  "运行 PROGRAM，捕获其 stdout 返回（bytevector，含任意字节）；
非零退出码抛错（不返回部分输出）。"
  (let ((port (apply open-pipe* OPEN_READ program args)))
    (let ((output (get-bytevector-all port)))
      (let ((status (close-pipe port)))
        (unless (zero? (status:exit-val status))
          (error "command failed" program (status:exit-val status)))
        output))))
