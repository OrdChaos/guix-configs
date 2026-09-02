;;; blue enroll 的 pinned 执行入口（Blue 只编排 argv；域机制在
;;; (guixcfg security enroll)）。为什么走子进程：blueprint 进程内
;;; 加载大模块图会在 link 阶段触发 guile out-of-range 崩溃
;;; （(guixcfg gsettings) 同款决策）。
;;;
;;; 用法（仓库根）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/enroll-cli.scm -- plan HOST
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/enroll-cli.scm -- run HOST
;;;
;;; plan：只读 preflight checks（soft：root-only 状态降级 info）+
;;; ENROLLMENT PLAN；零 mutation、无确认；任何 FAIL → exit 1。
;;; run：root 事务（preflight → 固件写入确认 → firmware enrollment
;;; → TPM enrollment → post-enrollment 验证）；exit 契约 = 模块头：
;;; 0 成功/已合规；1 前置失败（未 mutation）；2 部分 mutation 无法
;;; 安全继续；3 用户显式中止。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path
;; （从仓库根目录运行——Blue 的 %exec 以仓库根为工作目录）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg security enroll)
             (ice-9 match)
             (ice-9 rdelim))

(define (repo-root)
  ;; 本文件在 <root>/tools/ 下。
  (dirname (dirname (canonicalize-path (car (command-line))))))

(define (usage)
  (format (current-error-port)
          "usage: enroll-cli.scm -- plan HOST | run HOST~%")
  (exit 1))

;;; ────────────────────────────────────────────────────────────
;;; plan（只读；user 态与 blue -n 共用）

(define (plan-command host)
  (let ((root (repo-root)))
    (let loop ((checks (enroll-readonly-checks root host))
               (failures 0))
      (if (null? checks)
        (begin
         (unless (zero? failures)
           (format (current-error-port)
                   "enroll preflight: ~a check(s) failed~%" failures)
           (exit 1))
         (for-each
          (lambda (line) (format #t "~a~%" line))
          (enroll-plan-lines
           (classify-enrollment-probes (collect-enrollment-probes))
           host))
         (exit 0))
        (let* ((check (car checks))
               (result ((cdr check))))
          (match result
                 (('ok . detail)
                  (format #t "  [OK] ~a~a~%"
                          (car check)
                          (if detail (string-append ": " detail) "")))
                 (('info . detail)
                  (format #t "  [--] ~a~a~%"
                          (car check)
                          (if detail (string-append ": " detail) "")))
                 (('fail . detail)
                  (format (current-error-port) "  [FAIL] ~a: ~a~%"
                          (car check) detail))
                 (_ #t))
          (loop (cdr checks)
                (+ failures (if (and (pair? result)
                                     (eq? (car result) 'fail))
                              1 0))))))))

;;; ────────────────────────────────────────────────────────────
;;; run（root 事务；固件确认 UI 归本 CLI）

(define (firmware-confirm-ui status)
  "固件写入确认：打印当前状态/计划操作/回滚影响并逐字比对 token；
  EOF/其他输入一律返回 #f（→ 事务 exit 3）。"
  (for-each (lambda (line) (format #t "~a~%" line))
            (firmware-confirm-lines status))
  (force-output)
  (let ((input (read-line)))
    (unless (firmware-confirmed? input)
      (unless (eof-object? input)
        (format #t "Input does not match; firmware enrollment declined.~%")))
    (firmware-confirmed? input)))

(define (run-command host)
  (let ((root (repo-root)))
    (exit
     (enroll-transaction!
      root host
      ;; exec 契约：cwd = 仓库根（本进程由 Blue 以仓库根启动）。
      #:exec
      (lambda (argv)
        (format #t "  [exec] ~{ ~a~}~%" argv)
        (status:exit-val (apply system* argv)))
      #:on-firmware-confirm
      (lambda (status)
        (firmware-confirm-ui status))))))

;;; ────────────────────────────────────────────────────────────

(match (cdr (command-line))
       (("--" "plan" host) (plan-command host))
       (("--" "run" host) (run-command host))
       (("plan" host) (plan-command host))
       (("run" host) (run-command host))
       (_ (usage)))
