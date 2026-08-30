;;; Flatpak reconcile 运行时测试（fake binary）：
;;; PATH 注入记录 argv 的假 flatpak 脚本，真实执行 reconcile 层的
;;; sync/status/update/update-runtimes/remove/gc 函数，断言：
;;;   - EVERY installation operation 显式 --user；
;;;   - sync：remote 只在缺失时 add；install 只装 missing selected；
;;;     绝不 update 已装、绝不 uninstall；
;;;   - remote drift：fail，绝不 auto-modify/delete；
;;;   - pin：install 后 update --commit（pinned 1.16.6 install 无
;;;     --commit 的两步路径）；
;;;   - update：只有显式 unpinned selected targets，绝无裸 update；
;;;   - status：默认无 remote-info；--refresh 才 remote-info；
;;;   - remove：只 uninstall ref（不动数据/规则）；
;;;   - gc：只有 uninstall --unused + repair；
;;;   - network failure：显式命令干净失败，与 activation 零耦合
;;;     （activation 边界由 test-flatpak-service 静态回归固定）。
;;;
;;; 不触公网：假脚本只在进程内记录/回放。

(use-modules (guixcfg flatpak model)
             (guixcfg flatpak reconcile)
             (guix build utils)          ; mkdir-p、delete-file-recursively
             (ice-9 rdelim)              ; read-string
             (srfi srfi-1)
             (srfi srfi-13)              ; string-split、string-contains
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "flatpak-reconcile-exec")

;; ── fake binary 环境 ────────────────────────────────────────
(define %fp-dir (string-append "/tmp/guixcfg-fp-fake-"
                               (number->string (getpid))))
(define %fp-bin (string-append %fp-dir "/bin"))
(define %fp-log (string-append %fp-dir "/argv.log"))
(define %fp-list-app-out (string-append %fp-dir "/list-app.out"))
(define %fp-list-runtime-out (string-append %fp-dir "/list-runtime.out"))
(define %fp-info-out (string-append %fp-dir "/info.out"))
(define %fp-remotes-out (string-append %fp-dir "/remotes.out"))
(define %fp-remote-info-out (string-append %fp-dir "/remote-info.out"))

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
                           (display "  info)\n" p)
                           (display "    cat \"${FP_FAKE_INFO_OUT:-/dev/null}\" 2>/dev/null\n" p)
                           (display "    ;;\n" p)
                           (display "  remotes)\n" p)
                           (display "    cat \"${FP_FAKE_REMOTES_OUT:-/dev/null}\" 2>/dev/null\n" p)
                           (display "    ;;\n" p)
                           (display "  remote-info)\n" p)
                           (display "    cat \"${FP_FAKE_REMOTE_INFO_OUT:-/dev/null}\" 2>/dev/null\n" p)
                           (display "    ;;\n" p)
                           (display "esac\n" p)
                           (display "if [ -n \"${FP_FAKE_FAIL_ON:-}\" ]; then\n" p)
                           (display "  case \"$*\" in\n" p)
                           (display "    *\"$FP_FAKE_FAIL_ON\"*)\n" p)
                           (display "      echo \"fake flatpak failure\" >&2\n" p)
                           (display "      exit 1\n" p)
                           (display "      ;;\n" p)
                           (display "  esac\n" p)
                           (display "fi\n" p)
                           (display "exit 0\n" p)))
  (chmod (string-append %fp-bin "/flatpak") #o755)
  (setenv "PATH" (string-append %fp-bin ":" %fp-original-path))
  (setenv "FP_FAKE_LOG" %fp-log)
  (setenv "FP_FAKE_LIST_APP_OUT" %fp-list-app-out)
  (setenv "FP_FAKE_LIST_RUNTIME_OUT" %fp-list-runtime-out)
  (setenv "FP_FAKE_INFO_OUT" %fp-info-out)
  (setenv "FP_FAKE_REMOTES_OUT" %fp-remotes-out)
  (setenv "FP_FAKE_REMOTE_INFO_OUT" %fp-remote-info-out)
  (setenv "FP_FAKE_FAIL_ON" ""))

(define (fp-clear-log!)
  (false-if-exception (delete-file %fp-log)))

(define (fp-log-lines)
  (false-if-exception
   (filter (negate string-null?)
           (string-split
            (call-with-input-file %fp-log
              (lambda (p) (read-string p)))
            #\newline))))

(define (fp-log-has? fragment)
  (any (lambda (line) (string-contains line fragment))
       (or (fp-log-lines) '())))

(define (fp-log-pred? pred)
  (any pred (or (fp-log-lines) '())))

;; fixtures（与 test-flatpak-model 同构）
(define %fp-remotes
  (list (flatpak-remote
         (name 'flathub)
         (location "https://dl.flathub.org/repo/flathub.flatpakrepo")
         (repository-url "https://dl.flathub.org/repo/"))))
(define %fp-commit
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
(define %fp-apps
  (list (flatpak-application
         (name 'wechat) (id "com.tencent.WeChat")
         (remote 'flathub) (branch "stable"))
        (flatpak-application
         (name 'pinned) (id "org.example.Pinned")
         (remote 'flathub) (branch "stable")
         (commit %fp-commit))
        (flatpak-application
         (name 'unselected) (id "org.example.Unselected")
         (remote 'flathub) (branch "stable"))))

(dynamic-wind
 (lambda ()
   (fp-install-fake-flatpak))
 (lambda ()
   ;; ── 1. sync：add remote + install missing selected（只增）────
   (fp-write-file %fp-remotes-out "")
   (fp-write-file %fp-list-app-out "")
   (fp-clear-log!)
   (let ((missing (flatpak-sync #:remotes %fp-remotes
                                #:applications %fp-apps
                                #:selection '(wechat pinned))))
     (test-equal "sync returns the installed-missing set"
                 '(wechat pinned)
                 (map flatpak-application-name missing))
     (test-assert "sync: every invocation carries --user"
                  (not (fp-log-pred?
                        (lambda (line)
                          (not (string-contains line "--user"))))))
     (test-assert "sync: remote-add when missing (descriptor location)"
                  (fp-log-has?
                   "flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"))
     (test-assert "sync: installs missing selected app"
                  (fp-log-has?
                   "flatpak install --user -y flathub com.tencent.WeChat//stable"))
     (test-assert "sync: never installs unselected catalog app"
                  (not (fp-log-has? "org.example.Unselected")))
     (test-assert "sync: pinned app deploys via update --commit after install"
                  (let ((lines (fp-log-lines)))
                    (and (any (lambda (l)
                                (string-contains
                                 l
                                 "flatpak update --user --commit=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef org.example.Pinned//stable"))
                              lines)
                         (let ((install-i (list-index (lambda (l)
                                                        (and (string-contains l "install")
                                                             (string-contains l "org.example.Pinned")))
                                                      lines))
                               (update-i (list-index (lambda (l)
                                                       (string-contains l "--commit="))
                                                     lines)))
                           (and install-i update-i
                                (< install-i update-i))))))
     (test-assert "sync: never bare update (no ref-less update command)"
                  (not (fp-log-pred?
                        (lambda (line)
                          (and (string-contains line "flatpak update")
                               (not (string-contains line "--commit="))
                               (not (string-contains line "//")))))))
     (test-assert "sync: never uninstall"
                  (not (fp-log-has? "uninstall"))))

   ;; ── 2. sync：全部已装 + unmanaged/runtime → no-op ─────────
   (fp-write-file %fp-remotes-out
                  "flathub\thttps://dl.flathub.org/repo/\n")
   (fp-write-file %fp-list-app-out
                  "com.tencent.WeChat\norg.example.Pinned\norg.other.Unmanaged\norg.freedesktop.Platform\n")
   (fp-clear-log!)
   (let ((missing (flatpak-sync #:remotes %fp-remotes
                                #:applications %fp-apps
                                #:selection '(wechat pinned))))
     (test-equal "sync: nothing missing"
                 '() missing)
     (test-assert "sync: no remote-add when remote matches declaration"
                  (not (fp-log-has? "remote-add")))
     (test-assert "sync: no install when already installed"
                  (not (fp-log-has? "install")))
     (test-assert "sync: unmanaged app never appears in any argv"
                  (not (fp-log-has? "org.other.Unmanaged")))
     (test-assert "sync: runtime refs never appear in any argv"
                  (not (fp-log-has? "org.freedesktop.Platform"))))

   ;; ── 3. remote drift → fail，绝不 auto-modify ──────────────
   (fp-write-file %fp-remotes-out
                  "flathub\thttps://evil.example/repo/\n")
   (fp-write-file %fp-list-app-out "")
   (fp-clear-log!)
   (test-error "sync: remote drift fails loudly" #t
               (flatpak-sync #:remotes %fp-remotes
                             #:applications %fp-apps
                             #:selection '()))
   (test-assert "sync: drift never auto remote-modify/delete"
                (and (not (fp-log-has? "remote-modify"))
                     (not (fp-log-has? "remote-delete"))
                     (not (fp-log-has? "remote-add"))))

   ;; ── 4. update：显式 unpinned selected targets ─────────────
   (fp-write-file %fp-remotes-out
                  "flathub\thttps://dl.flathub.org/repo/\n")
   (fp-write-file %fp-list-app-out
                  "com.tencent.WeChat\norg.example.Unselected\norg.other.Unmanaged\n")
   (fp-clear-log!)
   (flatpak-update #:applications %fp-apps
                   #:selection '(wechat pinned unselected))
   (test-assert "update: explicit refs, pinned excluded, unmanaged excluded"
                (fp-log-has?
                 "flatpak update --user -y com.tencent.WeChat//stable org.example.Unselected//stable"))
   (test-assert "update: pinned app never in target list"
                (not (fp-log-has? "org.example.Pinned")))
   (test-assert "update: unmanaged app never in target list"
                (not (fp-log-has? "org.other.Unmanaged")))
   (fp-clear-log!)
   (flatpak-update #:applications %fp-apps #:selection '())
   (test-assert "update: no targets -> no bare update command"
                (not (fp-log-has? "flatpak update")))

   ;; ── 5. update-runtimes：枚举 + 显式 refs ──────────────────
   (fp-write-file %fp-list-runtime-out
                  "org.freedesktop.Platform\t23.08\norg.freedesktop.Platform\t24.08\n")
   (fp-clear-log!)
   (flatpak-update-runtimes)
   (test-assert "update-runtimes: explicit ref list from enumeration"
                (fp-log-has?
                 "flatpak update --user -y org.freedesktop.Platform//23.08 org.freedesktop.Platform//24.08"))
   (fp-write-file %fp-list-runtime-out "")
   (fp-clear-log!)
   (flatpak-update-runtimes)
   (test-assert "update-runtimes: none installed -> no update command"
                (not (fp-log-has? "flatpak update")))

   ;; ── 6. status：默认离线；--refresh 才 remote-info ─────────
   (fp-write-file %fp-list-app-out "com.tencent.WeChat\n")
   (fp-write-file %fp-info-out "Commit: 0123456789abcdef0123456789abcdef\n")
   (fp-clear-log!)
   (flatpak-status #:applications %fp-apps #:selection '(wechat))
   (test-assert "status: default is fully offline (no remote-info)"
                (not (fp-log-has? "remote-info")))
   (test-assert "status: reads installed commit via info"
                (fp-log-has?
                 "flatpak info --user --show-commit com.tencent.WeChat"))
   (fp-clear-log!)
   (flatpak-status #:refresh? #t
                   #:applications %fp-apps #:selection '(wechat))
   (test-assert "status --refresh queries remote current commit"
                (fp-log-has?
                 "flatpak remote-info --user --show-commit flathub com.tencent.WeChat//stable"))
   (test-assert "installed commit parsing strips 'Commit: ' prefix"
                (string=?
                 "0123456789abcdef0123456789abcdef"
                 (flatpak-installed-commit "com.tencent.WeChat")))

   ;; ── 7. remove：只 uninstall ref ───────────────────────────
   (fp-clear-log!)
   (flatpak-remove 'wechat #:applications %fp-apps)
   (test-assert "remove: explicit --user uninstall of the ref only"
                (fp-log-has?
                 "flatpak uninstall --user -y com.tencent.WeChat"))
   (test-assert "remove: no other mutation (no update/repair)"
                (and (not (fp-log-has? "flatpak update"))
                     (not (fp-log-has? "repair"))))
   (test-error "remove: unknown logical name fails fast" #t
               (flatpak-remove 'ghost #:applications %fp-apps))

   ;; ── 8. gc：只有维护操作 ───────────────────────────────────
   (fp-clear-log!)
   (flatpak-gc)
   (test-assert "gc: uninstall --unused --user"
                (fp-log-has? "flatpak uninstall --unused --user -y"))
   (test-assert "gc: repair --user"
                (fp-log-has? "flatpak repair --user"))
   (test-assert "gc: nothing else"
                (let ((lines (fp-log-lines)))
                  (= 2 (length lines))))

   ;; ── 9. network failure：干净失败、无半成品操作 ────────────
   (fp-write-file %fp-remotes-out "")
   (fp-write-file %fp-list-app-out "")
   (setenv "FP_FAKE_FAIL_ON" "install")
   (fp-clear-log!)
   (test-error "sync: install network failure propagates" #t
               (flatpak-sync #:remotes %fp-remotes
                             #:applications %fp-apps
                             #:selection '(wechat pinned)))
   (test-assert "sync: failure stops before pinned deploy"
                (not (fp-log-has? "--commit=")))
   (test-assert "sync: remote-add (local config) completed before failure"
                (fp-log-has? "remote-add"))
   (setenv "FP_FAKE_FAIL_ON" ""))
 (lambda ()
   (setenv "PATH" %fp-original-path)
   (for-each (lambda (var)
               (setenv var ""))
             '("FP_FAKE_LOG" "FP_FAKE_LIST_APP_OUT" "FP_FAKE_LIST_RUNTIME_OUT"
               "FP_FAKE_INFO_OUT" "FP_FAKE_REMOTES_OUT" "FP_FAKE_REMOTE_INFO_OUT"
               "FP_FAKE_FAIL_ON"))
   (false-if-exception (delete-file-recursively %fp-dir))))

(test-end "flatpak-reconcile-exec")
