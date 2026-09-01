;;; (guixcfg system reconfigure) gate transaction 单元测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 不触碰真实 /run/guixcfg、真实 HOME、不做真实 system
;;; reconfigure：全部经可注入边界（run-command / command-output /
;;; sleep-proc / gate-dir / home-dir / root）在 /tmp 沙箱内断言
;;; transaction 的 gate 状态机与 exit code 契约（0/1/2）。

(use-modules (guixcfg system reconfigure)
             (guixcfg system session-gate) ; gate 唯一 authority（alias 完整性断言）
             (guixcfg system deploy)      ; system-reconfigure-argv（断言 argv 形态）
             (ice-9 rdelim)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "reconfigure")

(define %base "/tmp/guixcfg-tx-test")
(define %counter 0)

(define (make-sandbox)
  (set! %counter (1+ %counter))
  (define dir (string-append %base "-" (number->string (getpid))
                             "-" (number->string %counter)))
  (define gate-dir (string-append dir "/gate"))
  (define home-dir (string-append dir "/home"))
  (mkdir dir)
  (mkdir gate-dir)
  (mkdir home-dir)
  (list dir gate-dir home-dir))

(define (gate-file gate-dir)
  (string-append gate-dir "/session-not-ready"))

(define (gate-closed? gate-dir)
  (file-exists? (gate-file gate-dir)))

(define (gate-content gate-dir)
  (call-with-input-file (gate-file gate-dir) read-string))

(define (home-link home-dir)
  (string-append home-dir "/.guix-home"))

(define (pivot home-dir)
  (string-append home-dir "/.guix-home.new"))

(define %fake-store-home "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home")

(define (safe-pivot! home-dir)
  (symlink %fake-store-home (pivot home-dir)))

(define (ready-home! home-dir)
  (symlink %fake-store-home (home-link home-dir)))

;; 空 readiness 输出 = 全部 capability 正常。
(define (no-herd-outputs) (lambda (argv) ""))

(define (expected-guix-argv)
  '("guix" "time-machine" "-C" "/repo/channels.lock.scm" "--"
           "system" "reconfigure" "-L" "/repo/modules"
           "modules/guixcfg/hosts/vm.scm"))

;; ── 1. system reconfigure 失败 → gate 重开、Home 不动、exit 1 ──

(let ((sandbox (make-sandbox))
      (log '()))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command
     (lambda (argv)
       (set! log (cons argv log))
       (if (equal? argv (expected-guix-argv)) 1 0))
     #:command-output (no-herd-outputs)
     #:sleep-proc (lambda (s) #t)))
  (test-equal "system failure: exit code 1" 1 result)
  (test-assert "system failure: gate reopened" (not (gate-closed? gate-dir)))
  (test-assert "system failure: Home untouched (no herd call)"
               (not (any (lambda (argv) (equal? (car argv) "herd")) log))))

;; ── 2. unsafe stale pivot → system switched、gate CLOSED、exit 2 ──

(let ((sandbox (make-sandbox))
      (log '()))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (call-with-output-file (pivot home-dir)
                         (lambda (p) (display "user data!\n" p)))
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command (lambda (argv) (set! log (cons argv log)) 0)
     #:command-output (no-herd-outputs)
     #:sleep-proc (lambda (s) #t)))
  (test-equal "unsafe pivot: exit code 2" 2 result)
  (test-assert "unsafe pivot: gate stays closed" (gate-closed? gate-dir))
  (test-assert "unsafe pivot: file untouched" (file-exists? (pivot home-dir)))
  (test-assert "unsafe pivot: no herd restart"
               (not (any (lambda (argv) (equal? (car argv) "herd")) log))))

;; ── 3. herd restart 被拒 → gate CLOSED、exit 2 ──

(let ((sandbox (make-sandbox)))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command
     (lambda (argv)
       (if (and (equal? (car argv) "herd")
                (equal? (cadr argv) "restart"))
         1 0))
     #:command-output (no-herd-outputs)
     #:sleep-proc (lambda (s) #t)))
  (test-equal "herd restart failure: exit code 2" 2 result)
  (test-assert "herd restart failure: gate stays closed" (gate-closed? gate-dir)))

;; ── 4. Home activation 超时 → gate CLOSED、exit 2、轮询 30 次 ──

(let ((sandbox (make-sandbox))
      (polls 0))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command (lambda (argv) 0)
     #:command-output (no-herd-outputs)
     #:sleep-proc (lambda (s) (set! polls (1+ polls)) #t)))
  (test-equal "activation timeout: exit code 2" 2 result)
  (test-equal "activation timeout: 30 polls" 30 polls)
  (test-assert "activation timeout: gate stays closed" (gate-closed? gate-dir)))

;; ── 5. 本次失败 activation 产生 safe pivot → 清理、exit 2 ──

(let ((sandbox (make-sandbox)))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command (lambda (argv) 0)
     #:command-output (no-herd-outputs)
     ;; 模拟 activation 失败残留 safe pivot（第一次 poll 时产生；
     ;; lstat 判定存在——悬空 symlink 对 file-exists? 是 #f）
     #:sleep-proc
     (lambda (s)
       (unless (false-if-exception (lstat (pivot home-dir)))
         (safe-pivot! home-dir))
       #t)))
  (test-equal "failed-activation pivot: exit code 2" 2 result)
  (test-assert "failed-activation pivot: cleaned up"
               (not (file-exists? (pivot home-dir))))
  (test-assert "failed-activation pivot: gate stays closed" (gate-closed? gate-dir)))

;; ── 6. readiness capability failed → gate CLOSED、exit 2 ──

(let ((sandbox (make-sandbox)))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (ready-home! home-dir)
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command (lambda (argv) 0)
     #:command-output
     (lambda (argv)
       (if (equal? (last argv) "account-state-ready")
         "Failed to start account-state-ready"
         ""))
     #:sleep-proc (lambda (s) #t)))
  (test-equal "readiness failure: exit code 2" 2 result)
  (test-assert "readiness failure: gate stays closed" (gate-closed? gate-dir)))

;; ── 7. 成功、Home 未变 → gate 重开、exit 0 ──

(let ((sandbox (make-sandbox)))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (ready-home! home-dir)
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command (lambda (argv) 0)
     #:command-output (no-herd-outputs)
     #:sleep-proc (lambda (s) #t)))
  (test-equal "success unchanged: exit code 0" 0 result)
  (test-assert "success unchanged: gate reopened" (not (gate-closed? gate-dir))))

;; ── 8. 成功、Home hot-switched → gate 重开、exit 0 ──

(let ((sandbox (make-sandbox)))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (ready-home! home-dir)          ; old home = aaaa
  (define switched? #f)
  (define result
    (reconfigure-transaction!
     "vm" "alice"
     #:root "/repo"
     #:gate-dir gate-dir
     #:home-dir home-dir
     #:run-command (lambda (argv) 0)
     #:command-output (no-herd-outputs)
     ;; 模拟激活期间 Home 链接被切换到新 generation
     #:sleep-proc
     (lambda (s)
       (unless switched?
         (set! switched? #t)
         (delete-file (home-link home-dir))
         (symlink "/gnu/store/cccccccccccccccccccccccccccccccc-home"
                  (home-link home-dir)))
       #t)))
  (test-equal "success changed: exit code 0" 0 result)
  (test-assert "success changed: gate reopened" (not (gate-closed? gate-dir))))

;; ── gate 内容与 readiness 集合契约 ──

(let ((sandbox (make-sandbox)))
  (define gate-dir (second sandbox))
  (define home-dir (third sandbox))
  (define captured-gate #f)
  (reconfigure-transaction!
   "vm" "alice"
   #:root "/repo"
   #:gate-dir gate-dir
   #:home-dir home-dir
   #:run-command
   (lambda (argv)
     (if (equal? argv (expected-guix-argv))
       (begin
        (set! captured-gate (gate-content gate-dir))
        (ready-home! home-dir)   ; 让激活立即就绪
        0)
       0))
   #:command-output (no-herd-outputs)
   #:sleep-proc (lambda (s) #t))
  (test-equal "gate file content expresses in-progress state"
              "A reconfigure is in progress.\n" captured-gate))

(test-equal "readiness capability set unchanged"
            '(guixcfg-secrets-deploy account-state-ready persistent-state-ready
                                     home-ready session-infra-ready interactive-session-ready)
            %readiness-capabilities)

(test-assert "reconfigure gate facts alias the session-gate authority"
             ;; 兼容导出名必须跟随 (guixcfg system session-gate) 的唯一
             ;; 定义，不能再自成第二份路径事实。
             (and (string=? %gate-directory %session-gate-directory)
                  (string=? %gate-file-name %session-gate-file-name)))

(test-end)
