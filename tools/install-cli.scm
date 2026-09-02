;;; blue install 的 pinned 执行入口（Blue 只编排 argv；域机制在
;;; (guixcfg system install)）。为什么走子进程：blueprint 进程内
;;; 加载大模块图会在 link 阶段触发 guile out-of-range 崩溃
;;; （(guixcfg gsettings) 同款决策，见 blueprint.scm 头注释）。
;;;
;;; 用法（仓库根）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/install-cli.scm -- plan HOST DEVICE
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/install-cli.scm -- run HOST DEVICE
;;;
;;; plan：只读 preflight checks + 状态检测 + INSTALL PLAN；零
;;; mutation、无确认；任何 FAIL → exit 1。
;;; run：root 事务（preflight → 破坏性确认 → 阶段执行 → 验证）；
;;; exit 契约 = 模块头：0 成功/已合规；1 前置失败（未 mutation）；
;;; 2 部分 mutation 无法安全继续；3 用户显式中止。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path
;; （从仓库根目录运行——Blue 的 %exec 以仓库根为工作目录）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg system install)
             (ice-9 match)
             (ice-9 rdelim))

(define (repo-root)
  ;; 本文件在 <root>/tools/ 下。
  (dirname (dirname (canonicalize-path (car (command-line))))))

(define (usage)
  (format (current-error-port)
          "usage: install-cli.scm -- plan HOST DEVICE | run HOST DEVICE~%")
  (exit 1))

;;; ────────────────────────────────────────────────────────────
;;; plan（只读；user 态与 blue -n 共用）

(define (plan-command host device)
  (let ((root (repo-root)))
    (let loop ((checks (install-preflight-checks root host device))
               (failures 0))
      (if (null? checks)
        (begin
         (unless (zero? failures)
           (format (current-error-port)
                   "install preflight: ~a check(s) failed~%" failures)
           (exit 1))
         (for-each (lambda (line) (format #t "~a~%" line))
                   (install-plan-lines
                    (detect-install-state root host device)))
         (exit 0))
        (let* ((check (car checks))
               (result ((cdr check))))
          (match result
                 (('ok . detail)
                  (format #t "  [OK] ~a~a~%"
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
;;; run（root 事务；确认 UI 归本 CLI——与 blueprint 的职责边界同：
;;; Blue owns argv/handoff，机制与 UI 在域侧）

(define (confirm-device-ui state device)
  "破坏性确认：打印 §8 格式并逐字比对完整 DEVICE；EOF/其他输入一律
  返回 #f（→ 事务 exit 3）。"
  (for-each (lambda (line) (format #t "~a~%" line))
            (install-confirm-lines state))
  (force-output)
  (let ((input (read-line)))
    (unless (install-confirmed? input device)
      (unless (eof-object? input)
        (format #t "Input does not match; aborted, nothing was modified.~%")))
    (install-confirmed? input device)))

(define (run-command host device)
  (let ((root (repo-root)))
    (exit
     (install-transaction!
      root host device
      ;; exec 契约：cwd = 仓库根（本进程由 Blue 以仓库根启动）。
      #:exec
      (lambda (argv)
        (format #t "  [exec] ~{ ~a~}~%" argv)
        (status:exit-val (apply system* argv)))
      #:on-confirm
      (lambda (state)
        (confirm-device-ui state device))))))

;;; ────────────────────────────────────────────────────────────

(match (cdr (command-line))
       (("--" "plan" host device) (plan-command host device))
       (("--" "run" host device) (run-command host device))
       (("plan" host device) (plan-command host device))
       (("run" host device) (run-command host device))
       (_ (usage)))
