;;; GSettings 投影执行入口（tooling plane，pinned 环境）：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/gsettings.scm -- status
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/gsettings.scm -- apply
;;;   guix time-machine -C channels.lock.scm -- \
;;;     repl tools/gsettings.scm -- dry-run-apply
;;;
;;; 为什么是 pinned 子进程而不是 blueprint 直接执行（决策记录）：
;;;   1. desired state 事实源是 apps registry——39 个 application
;;;      definition 中 8 个依赖 channel 模块（nonguix/virelith/
;;;      rosenthal/saayix），且 definition 引用的 guix 包必须来自
;;;      pinned channels（`guix time-machine shell` 的 GUILE_LOAD_PATH
;;;      只带宿主机 guix current——宿主机 guix 新版本已把 fastfetch
;;;      改名 fastfetch-minimal，直接解析会 Unbound variable）；
;;;   2. blueprint 编译期导入非平凡新模块会在外层 link 阶段触发
;;;      guile out-of-range 崩溃（嵌套编译，实测）。
;;;   因此 blueprint 只做 action 校验与调度，域执行全部在本脚本
;;;   （与 blue check → tests/run-tests.scm 同一模式）。
;;;
;;; 运行前提：gsettings/dconf 经会话 PATH 解析（VM 内为 pinned
;;; system profile；脚本不硬编码路径）；~/.config/dconf 是
;;; disposable runtime projection，绝不持久化。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg gsettings model)
             (guixcfg gsettings serialize)
             (guixcfg gsettings reconcile)
             (guixcfg apps model)       ; applications-gsettings
             (guixcfg apps registry)    ; %applications（唯一启用事实源）
             (ice-9 match))

(define (usage)
  (format (current-error-port)
          "Usage: guix time-machine -C channels.lock.scm -- repl ~
tools/gsettings.scm -- ACTION~%actions: status | apply | dry-run-apply~%")
  (exit 1))

(define (print-lines lines)
  (for-each (lambda (line) (format #t "~a~%" line)) lines))

(define (desired-state)
  (gsettings-desired-state (applications-gsettings %applications)))

(define (main args)
  (match args
         (("status")
          (print-lines (gsettings-status-format
                        (gsettings-status (desired-state)))))
         (("dry-run-apply")
          ;; dry-run 契约：真实只读 status/diff + plan；零 mutation
          ;; （绝不 invoke dconf load）。
          (let ((desired (desired-state)))
            (print-lines (gsettings-status-format (gsettings-status desired)))
            (format #t "dry-run: ~a managed key(s) would be applied~%"
                    (length (gsettings-plan desired)))))
         (("apply")
          (let ((desired (desired-state)))
            (format #t "gsettings apply: ~a managed key(s)~%"
                    (gsettings-apply! desired))))
         (_ (usage))))

(main (cdr (command-line)))
