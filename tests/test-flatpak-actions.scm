;;; Blue flatpak 命令的 invocation 契约与 dry-run plan 测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; fake flatpak 环境（同 test-flatpak-reconcile-exec 的模式）：
;;; PATH 注入记录 argv 的假脚本；只测试 reconcile 的只读 plan 函数
;;; 与 action 契约——blue -n flatpak 的"绝不 mutate"由这些只读
;;; 函数保证，这里断言 plan 执行后 argv log 里没有任何 mutation
;;; 命令（install/uninstall/update/remote-add/remote-modify/
;;; remote-delete/repair）。

(use-modules (guixcfg flatpak model)
             (guixcfg flatpak reconcile)
             (guixcfg flatpak registry)
             (guix build utils)          ; mkdir-p、delete-file-recursively
             (ice-9 rdelim)              ; read-string
             (srfi srfi-1)
             (srfi srfi-13)              ; string-contains
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "flatpak-actions")

;; ── fake binary 环境 ────────────────────────────────────────

(define %fp-dir (string-append "/tmp/guixcfg-fp-actions-"
                               (number->string (getpid))))
(define %fp-bin (string-append %fp-dir "/bin"))
(define %fp-log (string-append %fp-dir "/argv.log"))
(define %fp-list-app-out (string-append %fp-dir "/list-app.out"))
(define %fp-list-runtime-out (string-append %fp-dir "/list-runtime.out"))
(define %fp-remotes-out (string-append %fp-dir "/remotes.out"))
(define %fp-original-path (getenv "PATH"))

(define (fp-write-file path content)
  (call-with-output-file path (lambda (p) (display content p))))

(define (fp-install-fake-flatpak)
  (mkdir-p %fp-bin)
  (call-with-output-file (string-append %fp-bin "/flatpak")
                         (lambda (p)
                           (display "#!/bin/sh\n" p)
                           (display "printf 'flatpak %s\\n' \"$*\" >> \"${FP_FAKE_LOG:?}\"\n" p)
                           (display "case \"$1\" in\n" p)
                           (display "  list)\n" p)
                           (display "    case \"$*\" in\n" p)
                           (display "      *--runtime*) cat \"${FP_FAKE_LIST_RUNTIME_OUT:-/dev/null}\" 2>/dev/null ;;\n" p)
                           (display "      *) cat \"${FP_FAKE_LIST_APP_OUT:-/dev/null}\" 2>/dev/null ;;\n" p)
                           (display "    esac\n" p)
                           (display "    ;;\n" p)
                           (display "  remotes)\n" p)
                           (display "    cat \"${FP_FAKE_REMOTES_OUT:-/dev/null}\" 2>/dev/null\n" p)
                           (display "    ;;\n" p)
                           (display "  info)\n" p)
                           (display "    printf 'Commit: deadbeef\\n'\n" p)
                           (display "    ;;\n" p)
                           (display "  *)\n" p)
                           (display "    exit 0\n" p)
                           (display "    ;;\n" p)
                           (display "esac\n" p)))
  (chmod (string-append %fp-bin "/flatpak") #o755))

(define (fp-setup!)
  (fp-install-fake-flatpak)
  (setenv "PATH" (string-append %fp-bin ":" %fp-original-path))
  (setenv "FP_FAKE_LOG" %fp-log)
  (setenv "FP_FAKE_LIST_APP_OUT" %fp-list-app-out)
  (setenv "FP_FAKE_LIST_RUNTIME_OUT" %fp-list-runtime-out)
  (setenv "FP_FAKE_REMOTES_OUT" %fp-remotes-out))

(define (fp-log-lines)
  (call-with-input-file %fp-log
                        (lambda (p)
                          (let loop ((acc '()))
                            (let ((l (read-line p)))
                              (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

(define (fp-log-contains? needle)
  (any (cut string-contains <> needle) (fp-log-lines)))

(fp-setup!)

;; ── action 契约 ─────────────────────────────────────────────

(test-equal "action registry: exactly the 7 supported actions"
            '((sync . #f) (status . #t) (update . #f) (update-runtimes . #f)
                          (remove . #f) (remote-replace . #f) (gc . #f))
            %flatpak-actions)

(test-equal "flatpak-actions lists names in canonical order"
            '("sync" "status" "update" "update-runtimes" "remove" "remote-replace" "gc")
            (flatpak-actions))

(test-equal "validate: status (no flag)"
            '(status ()) (flatpak-validate-action-arguments "status" '()))

(test-equal "validate: status --refresh"
            '(status (refresh)) (flatpak-validate-action-arguments "status" '("--refresh")))

(test-equal "validate: sync"
            '(sync ()) (flatpak-validate-action-arguments "sync" '()))

(test-equal "validate: update"
            '(update ()) (flatpak-validate-action-arguments "update" '()))

(test-equal "validate: update-runtimes"
            '(update-runtimes ()) (flatpak-validate-action-arguments "update-runtimes" '()))

(test-equal "validate: remove with one argument"
            '(remove ("qq")) (flatpak-validate-action-arguments "remove" '("qq")))

(test-equal "validate: remote-replace with one argument"
            '(remote-replace ("flathub"))
            (flatpak-validate-action-arguments "remote-replace" '("flathub")))

(test-equal "validate: gc"
            '(gc ()) (flatpak-validate-action-arguments "gc" '()))

(test-assert "validate: missing action -> #f"
             (not (flatpak-validate-action-arguments #f '())))

(test-assert "validate: unknown action -> #f (no fallback)"
             (not (flatpak-validate-action-arguments "foobar" '())))

(test-assert "validate: remove without argument -> #f"
             (not (flatpak-validate-action-arguments "remove" '())))

(test-assert "validate: remove with two arguments -> #f"
             (not (flatpak-validate-action-arguments "remove" '("a" "b"))))

(test-assert "validate: status with unknown flag -> #f"
             (not (flatpak-validate-action-arguments "status" '("--bogus"))))

(test-assert "validate: sync with extra argument -> #f"
             (not (flatpak-validate-action-arguments "sync" '("extra"))))

;; ── dry-run plan（只读；绝不 mutate） ───────────────────────

;; 初始状态：无 remote、无已装 app/runtime。
(fp-write-file %fp-remotes-out "")
(fp-write-file %fp-list-app-out "")
(fp-write-file %fp-list-runtime-out "")

(test-assert "sync-plan: missing remote -> would add (descriptor + transport)"
             (let ((lines (flatpak-sync-plan %flatpak-remotes
                                             %flatpak-applications
                                             %flatpak-selection)))
               (any (lambda (l) (string-contains l "would add remote")) lines)))

(test-assert "sync-plan: uninstalled selected app -> would install with remote"
             (let ((lines (flatpak-sync-plan %flatpak-remotes
                                             %flatpak-applications
                                             %flatpak-selection)))
               (any (lambda (l)
                      (and (string-contains l "would install")
                           (string-contains l " from ")))
                    lines)))

(test-assert "sync-plan: performs no mutation (log has only read-only commands)"
             (begin
              (flatpak-sync-plan %flatpak-remotes %flatpak-applications %flatpak-selection)
              (not (any (lambda (l)
                          (or (string-contains l " install")
                              (string-contains l " uninstall")
                              (string-contains l " update")
                              (string-contains l "remote-add")
                              (string-contains l "remote-modify")
                              (string-contains l "remote-delete")
                              (string-contains l "repair")))
                        (fp-log-lines)))))

;; update-plan：装两个（一个 unpinned selected，一个 pinned selected，
;; 一个 unselected）→ 只出 unpinned selected 的 ref。
(fp-write-file %fp-list-app-out
               (string-append
                (flatpak-application-id (car (flatpak-select-applications %flatpak-selection %flatpak-applications)))
                "\n"))
(test-assert "update-plan: yields refs for selected+installed+unpinned only"
             (let* ((selected (flatpak-select-applications %flatpak-selection %flatpak-applications))
                    (installed-ids (flatpak-list-installed-apps))
                    (expected
                     (map flatpak-application-ref
                          (filter (lambda (a)
                                    (and (member (flatpak-application-id a) installed-ids)
                                         (not (flatpak-application-commit a))))
                                  selected))))
               (equal? expected
                       (flatpak-update-plan %flatpak-applications %flatpak-selection))))

;; update-runtimes-plan：空输出 → 空计划；有输出 → ref 列表。
(test-equal "update-runtimes-plan: no runtimes -> empty"
            '() (flatpak-update-runtimes-plan))
(fp-write-file %fp-list-runtime-out "org.freedesktop.Platform 23.08\n")
(test-equal "update-runtimes-plan: yields refs"
            '("org.freedesktop.Platform//23.08")
            (flatpak-update-runtimes-plan))

;; remove-plan：已知 name → app；未知 name → 同 remove 的 fail-fast。
(test-assert "remove-plan: known logical name resolves to an application"
             (let ((name (flatpak-application-name (car %flatpak-applications))))
               (flatpak-application? (flatpak-remove-plan name %flatpak-applications))))

(test-assert "remove-plan: unknown name fails fast mentioning the name"
             (let ((msg (string-join
                         (let walk ((x (catch #t
                                         (lambda () (flatpak-remove-plan 'no-such-app
                                                                         %flatpak-applications)
                                           '())
                                         (lambda (key . args) args))))
                           (cond ((string? x) (list x))
                             ((symbol? x) (list (symbol->string x)))
                             ((pair? x) (append (walk (car x)) (walk (cdr x))))
                             (else '())))
                         " ")))
               (string-contains msg "no-such-app")))

;; replace-remote-plan：无 remote → #f；有 remote → url。
(test-assert "replace-remote-plan: unconfigured remote -> #f"
             (not (flatpak-replace-remote-plan (car %flatpak-remotes))))
(fp-write-file %fp-remotes-out "flathub\thttps://example.org/repo\n")
(test-assert "replace-remote-plan: configured remote -> current url"
             (let ((remote (car %flatpak-remotes)))
               (string? (flatpak-replace-remote-plan remote))))

;; gc-commands：两条 argv，全部显式 --user，无 sudo/system，无 shell 拼接。
(test-equal "gc-commands: exactly two commands"
            2 (length (flatpak-gc-commands)))

(test-assert "gc-commands: every mutation explicit --user, never --system/sudo"
             (let ((all (flatpak-gc-commands)))
               (and (every (lambda (argv) (member "--user" argv)) all)
                    (not (any (lambda (argv) (member "--system" argv)) all))
                    (not (any (lambda (argv) (member "sudo" argv)) all))
                    (every list? all))))

;; flatpak-binary 解析契约：会话 PATH 优先（显式覆盖），随后 guix
;; 标准安装位置（VM system profile / 用户 profile）——ssh 非 login
;; shell 无 system profile PATH 也能解析（绝不依赖 /etc/profile）。
(test-equal "flatpak-binary-candidates: PATH first, then guix standard locations"
            (list (string-append %fp-bin "/flatpak")
                  "/run/current-system/profile/bin/flatpak"
                  (string-append (getenv "HOME") "/.guix-profile/bin/flatpak"))
            (flatpak-binary-candidates))

(test-equal "flatpak-binary: resolves the PATH candidate when present"
            (string-append %fp-bin "/flatpak")
            (flatpak-binary))

(test-end)

;; 恢复环境。
(setenv "PATH" %fp-original-path)
(false-if-exception (delete-file-recursively %fp-dir))
