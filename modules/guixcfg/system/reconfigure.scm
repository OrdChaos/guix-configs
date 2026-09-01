;;; Reconfigure gate transaction（机制事实源，Guile 实现）。
;;;
;;; 本模块是已删除的 tools/reconfigure.sh 的等价迁移（迁移
;;; transaction，不重新设计 transaction；docs/operations/
;;; reconfigure.md 的事务语义）。职责：system reconfigure + 成功后
;;; 热激活绑定的 Guix Home + readiness gate 事务语义
;;; （docs/architecture/accounts-sessions.md）：
;;;
;;;   close gate（新 interactive session 被拒；已有 session 不动）
;;;     → guix time-machine … system reconfigure
;;;     → shepherd 升级自动 restart 变化的 one-shot 服务（secrets
;;;       代际发布、password 投影、Home 热激活）
;;;     → 验证：Home 链接状态 + 各 readiness capability 无 failed
;;;     → open gate
;;;
;;; 为什么需要显式热激活验证：`guix system reconfigure` 的服务升级
;;; 对 one-shot 服务是 fire-and-forget：shepherd 把 activate 进程
;;; fork 出去即视为成功——Home activate 失败不会反馈到 reconfigure
;;; 退出码。这里在 reconfigure 成功后显式 restart + 验证链接状态，
;;; 失败时明确报告。
;;;
;;; 错误语义（exit code 契约，Blue 外层必须原样保留）：
;;;   0 = 完整成功（gate 重新打开）
;;;   1 = system reconfigure 失败 → Home 不动、gate 重开（system
;;;       没变，没有新的不一致）
;;;   2 = system 已 switched，但 Home 热激活/readiness 阶段失败 →
;;;       不回滚 system；gate 保持 CLOSED（新 session 拒绝），修复
;;;       后重跑 blue reconfigure HOST 恢复（无需 reboot）
;;;
;;; Home stale pivot 经 (guixcfg home pivot) 直接 Scheme 调用
;;; （remove-stale-pivot!）——不再有 CLI adapter。
;;;
;;; 可注入边界（单元测试用；不做真实 system reconfigure）：
;;;   run-command     argv → exit status
;;;   command-output  argv → stdout 字符串（herd status 捕获）
;;;   sleep-proc      secs → #t
;;;   gate-dir / home-dir / root   文件系统与路径边界
;;; 生产默认值：system* / invoke-capture / sleep /
;;; /run/guixcfg / /home/<home-user> / repository-root。

(define-module (guixcfg system reconfigure)
               #:use-module (guixcfg system deploy)   ; system-reconfigure-argv
               #:use-module (guixcfg utils repository-source) ; repository-root
               #:use-module (guixcfg utils process)   ; invoke-capture
               #:use-module (guixcfg home pivot)      ; remove-stale-pivot!
               #:use-module (ice-9 format)
               #:use-module (srfi srfi-1)             ; find
               #:use-module (srfi srfi-13)            ; string-contains / string-prefix?
               #:use-module (srfi srfi-26)            ; cut
               #:export (%gate-directory
                         %gate-file-name
                         %readiness-capabilities
                         reconfigure-transaction!))

;; gate 路径/协议不变（accounts-sessions.md 的 readiness gate）。
(define %gate-directory "/run/guixcfg")
(define %gate-file-name "session-not-ready")

;; 当前 authoritative capability 集合（原 tools/reconfigure.sh 列表；
;; guixcfg-password-project 是已删除的旧 provision，见
;; docs/architecture/upstream-boundaries.md）。
(define %readiness-capabilities
  '(guixcfg-secrets-deploy account-state-ready persistent-state-ready
                           home-ready session-infra-ready interactive-session-ready))

(define (symlink-target path)
  "PATH 是 symlink → 其 target；否则 #f。不 follow 非 symlink 对象。"
  (and (false-if-exception
        (eq? 'symlink (stat:type (lstat path))))
       (false-if-exception (readlink path))))

(define (home-activation-ready? home-link)
  "Home 热激活就绪判定：~/.guix-home 是 symlink 且 target 以
/gnu/store/ 开头（与原 shell 的轮询判定一致）。"
  (and=> (symlink-target home-link)
         (cut string-prefix? "/gnu/store/" <>)))

(define* (reconfigure-transaction! host home-user
                                   #:key
                                   (root (repository-root))
                                   (run-command (lambda (argv) (apply system* argv)))
                                   (command-output
                                    (lambda (argv)
                                      (false-if-exception
                                       (apply invoke-capture argv))))
                                   (sleep-proc (lambda (secs) (sleep secs) #t))
                                   (gate-dir %gate-directory)
                                   (home-dir (string-append "/home/" home-user)))
         "执行完整 gate transaction，返回 exit code（0/1/2，语义见头部）。
HOST 与 HOME-USER 由调用方显式传入（Blue 的 privilege handoff）。"
         (define gate (string-append gate-dir "/" %gate-file-name))
         (define home-link (string-append home-dir "/.guix-home"))
         (define pivot (string-append home-dir "/.guix-home.new"))
         
         (define (close-gate!)
           (unless (file-exists? gate-dir)
             (mkdir gate-dir))
           (call-with-output-file gate
                                  (lambda (p) (display "A reconfigure is in progress.\n" p))))
         
         (define (open-gate!)
           (false-if-exception (delete-file gate)))
         
         (close-gate!)
         (let ((old-home (symlink-target home-link)))
           ;; 1. system reconfigure（失败则 Home 完全不动、gate 重新打开）
           (if (not (zero? (run-command (system-reconfigure-argv root host))))
             (begin
              (open-gate!)
              (format (current-error-port)
                      "reconfigure: system reconfigure FAILED; Home left untouched;~%  gate reopened (no state changed).~%")
              1)
             ;; 2. pivot preflight：保守清理上次失败激活的 stale pivot
             (let ((preflight (remove-stale-pivot! pivot)))
               (if (eq? preflight 'unsafe)
                 (begin
                  (format (current-error-port)
                          "reconfigure: stale pivot ~a exists but is NOT a recognizable~%  Guix Home pivot symlink (plain file/directory/unknown link);~%  refusing to touch it. Investigate manually, then retry.~%  Gate remains CLOSED (system switched; Home not activated).~%"
                          pivot)
                  2)
                 (let ((had-pivot-before (file-exists? pivot)))
                   ;; 3. Home 热激活（幂等；herd restart 被拒则失败）
                   (if (not (zero? (run-command
                                    `("herd" "restart"
                                             ,(string-append "guix-home-" home-user)))))
                     (begin
                      (format (current-error-port)
                              "reconfigure: system generation switched, but Home hot-activation~%  could not be started (herd restart rejected). Gate remains~%  CLOSED; next boot recovers via the official service.~%")
                      2)
                     ;; 4. 验证：轮询链接直到出现且指向 store
                     (let ((ok? (let loop ((i 0))
                                  (cond
                                    ((home-activation-ready? home-link) #t)
                                    ((< i 30) (sleep-proc 1) (loop (1+ i)))
                                    (else #f))))
                           (new-home (symlink-target home-link)))
                       (if (or (not ok?) (file-exists? pivot))
                         (begin
                          ;; 本次失败激活产生的 safe pivot 清理
                          ;; （不覆盖原始 activation 错误）
                          (when (and (not had-pivot-before)
                                     (file-exists? pivot))
                            (unless (eq? 'safe-stale-pivot
                                         (remove-stale-pivot! pivot))
                              (format (current-error-port)
                                      "reconfigure: additionally, cleanup of the stale pivot from~%  THIS failed activation failed; manual attention required:~%  ~a~%"
                                      pivot)))
                          (format (current-error-port)
                                  "reconfigure: system generation switched OK, but Home hot-activation~%  FAILED (old Home: ~a; system is NOT rolled back).~%  Gate remains CLOSED (new interactive sessions refused).~%  Investigate: pivot residue ~a, or ~a occupied by a non-symlink.~%  Fix, then re-run blue reconfigure ~a to recover without reboot.~%"
                                  (or old-home "none") pivot home-link host)
                          2)
                         ;; 5. readiness 复查：各 capability 无 failed
                         (let ((failed
                                (find
                                 (lambda (svc)
                                   (let ((out (command-output
                                               `("herd" "status"
                                                        ,(symbol->string svc)))))
                                     (and (string? out)
                                          (string-contains out "Failed to start"))))
                                 %readiness-capabilities)))
                           (if failed
                             (begin
                              (format (current-error-port)
                                      "reconfigure: capability ~a is FAILED; gate remains CLOSED.~%  Fix the cause, then re-run blue reconfigure ~a to recover.~%"
                                      failed host)
                              2)
                             (begin
                              (open-gate!)
                              (if (equal? new-home old-home)
                                (format #t
                                        "reconfigure: OK (Home closure unchanged; link idempotent: ~a)~%"
                                        new-home)
                                (format #t
                                        "reconfigure: OK (Home hot-switched ~a -> ~a)~%"
                                        old-home new-home))
                              0))))))))))))
