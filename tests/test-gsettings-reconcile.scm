;;; GSettings reconcile 执行测试（fake gsettings/dconf 环境，同
;;; test-flatpak-actions / test-flatpak-reconcile-exec 的模式）：
;;; PATH 注入记录 argv 的假脚本 + env 驱动的脚本化输出；绝不访问
;;; 用户真实 dconf。
;;;
;;; 覆盖：
;;;   action 校验（status/apply canonical；unknown/多余参数 → #f）；
;;;   status 五态（synced / drifted / missing-schema / missing-key /
;;;     invalid-desired-value）；
;;;   apply 精确 argv（dconf load /）+ stdin 内容 = 序列化结果；
;;;   apply 对三类声明错误 fail-loud；
;;;   status/plan 绝不 invoke dconf（dry-run 的只读半边）。

(use-modules (guixcfg gsettings model)
             (guixcfg gsettings serialize)
             (guixcfg gsettings reconcile)
             (guix build utils)          ; mkdir-p、delete-file-recursively
             (ice-9 rdelim)              ; read-string
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; ── fake 环境 ──────────────────────────────────────────────

(define %gs-dir (string-append "/tmp/guixcfg-gs-"
                               (number->string (getpid))))
(define %gs-bin (string-append %gs-dir "/bin"))
(define %gs-log (string-append %gs-dir "/argv.log"))
(define %gs-dconf-stdin (string-append %gs-dir "/dconf.stdin"))
(define %gs-original-path (getenv "PATH"))

(define (gs-write-file path content)
  (call-with-output-file path (lambda (p) (display content p))))

(define (gs-install-fakes!)
  (mkdir-p %gs-bin)
  (call-with-output-file
   (string-append %gs-bin "/gsettings")
   (lambda (p)
     (display "#!/bin/sh\n" p)
     (display "printf 'gsettings %s\\n' \"$*\" >> \"${GS_FAKE_LOG:?}\"\n" p)
     (display "case \"$1\" in\n" p)
     (display "  list-keys)\n" p)
     (display "    if [ \"$2\" = \"${GS_FAKE_MISSING_SCHEMA:-__none__}\" ]; then exit 1; fi\n" p)
     (display "    printf '%s\\n' \"${GS_FAKE_KEYS:-}\"\n" p)
     (display "    ;;\n" p)
     (display "  range)\n" p)
     (display "    if [ \"$2\" = \"${GS_FAKE_MISSING_KEY:-__none__}\" ]; then exit 1; fi\n" p)
     (display "    printf 'type %s\\n' \"${GS_FAKE_RANGE_TYPE:-b}\"\n" p)
     (display "    ;;\n" p)
     (display "  get)\n" p)
     (display "    if [ \"$2\" = \"${GS_FAKE_MISSING_KEY:-__none__}\" ]; then exit 1; fi\n" p)
     (display "    printf '%s\\n' \"${GS_FAKE_GET_VALUE:-true}\"\n" p)
     (display "    ;;\n" p)
     (display "  *)\n" p)
     (display "    exit 1\n" p)
     (display "    ;;\n" p)
     (display "esac\n" p)))
  (call-with-output-file
   (string-append %gs-bin "/dconf")
   (lambda (p)
     (display "#!/bin/sh\n" p)
     (display "printf 'dconf %s\\n' \"$*\" >> \"${GS_FAKE_LOG:?}\"\n" p)
     (display "cat > \"${GS_FAKE_DCONF_STDIN:?}\"\n" p)
     (display "exit 0\n" p)))
  (chmod (string-append %gs-bin "/gsettings") #o755)
  (chmod (string-append %gs-bin "/dconf") #o755))

(define (gs-setup!)
  (gs-install-fakes!)
  (setenv "PATH" (string-append %gs-bin ":" %gs-original-path))
  (setenv "GS_FAKE_LOG" %gs-log)
  (setenv "GS_FAKE_DCONF_STDIN" %gs-dconf-stdin)
  (setenv "GS_FAKE_KEYS" "restore-session\nshow-line-numbers\n")
  (setenv "GS_FAKE_RANGE_TYPE" "b")
  (setenv "GS_FAKE_GET_VALUE" "true")
  (unsetenv "GS_FAKE_MISSING_SCHEMA")
  (unsetenv "GS_FAKE_MISSING_KEY"))

(define (gs-log-lines)
  (if (file-exists? %gs-log)
    (call-with-input-file %gs-log
                          (lambda (p)
                            (let loop ((acc '()))
                              (let ((l (read-line p)))
                                (if (eof-object? l)
                                  (reverse acc)
                                  (loop (cons l acc)))))))
    '()))

(define (gs-log-contains? substring)
  (any (lambda (line) (string-contains line substring))
       (gs-log-lines)))

(define (gs-reset-log!)
  (false-if-exception (delete-file %gs-log)))

(define %k-restore
  (gsettings-setting (schema "org.gnome.TextEditor")
                     (key "restore-session")
                     (value "false")))

(test-begin "gsettings-reconcile")

(gs-setup!)

;; ── action 校验 ────────────────────────────────────────────

(test-equal "action: status canonical"
            '(status ())
            (gsettings-validate-action-arguments "status" '()))
(test-equal "action: apply canonical"
            '(apply ())
            (gsettings-validate-action-arguments "apply" '()))
(test-assert "action: unknown action -> #f"
             (not (gsettings-validate-action-arguments "foo" '())))
(test-assert "action: extra argument -> #f"
             (not (gsettings-validate-action-arguments "status" '("x"))))
(test-assert "action: non-string action -> #f"
             (not (gsettings-validate-action-arguments 'status '())))

;; ── status 五态 ────────────────────────────────────────────

(test-equal "status: synced when runtime equals desired"
            '(synced "false" "false")
            (begin
             (setenv "GS_FAKE_GET_VALUE" "false")
             (let ((entry (car (gsettings-status (list %k-restore)))))
               (list (caddr entry) (cadddr entry)
                     (car (cddddr entry))))))

(test-equal "status: drifted when runtime differs"
            '(drifted "false" "true")
            (begin
             (setenv "GS_FAKE_GET_VALUE" "true")
             (let ((entry (car (gsettings-status (list %k-restore)))))
               (list (caddr entry) (cadddr entry)
                     (car (cddddr entry))))))

(test-equal "status: missing-schema when list-keys fails"
            'missing-schema
            (begin
             (setenv "GS_FAKE_MISSING_SCHEMA" "org.gnome.TextEditor")
             (caddr (car (gsettings-status (list %k-restore))))))

(test-equal "status: missing-key when key absent from list-keys"
            'missing-key
            (begin
             (unsetenv "GS_FAKE_MISSING_SCHEMA")
             (setenv "GS_FAKE_KEYS" "other-key\n")
             (caddr (car (gsettings-status (list %k-restore))))))

(test-equal "status: invalid-desired-value when shallow check fails"
            'invalid-desired-value
            (begin
             (setenv "GS_FAKE_KEYS" "restore-session\n")
             (setenv "GS_FAKE_RANGE_TYPE" "b")
             (let ((bad (gsettings-setting
                         (schema "org.gnome.TextEditor")
                         (key "restore-session")
                         (value "notabool"))))
               (caddr (car (gsettings-status (list bad)))))))

;; ── plan / apply ───────────────────────────────────────────

(test-equal "plan: synced entry excluded"
            '()
            (begin
             (setenv "GS_FAKE_GET_VALUE" "false")
             (gsettings-plan (list %k-restore))))

(test-equal "plan: drifted entry included"
            'drifted
            (begin
             (setenv "GS_FAKE_GET_VALUE" "true")
             (caddr (car (gsettings-plan (list %k-restore))))))

(test-assert "apply: exactly dconf load / with serialized stdin"
             (begin
              (gs-reset-log!)
              (setenv "GS_FAKE_KEYS" "restore-session\nshow-line-numbers\n")
              (unsetenv "GS_FAKE_MISSING_SCHEMA")
              (unsetenv "GS_FAKE_MISSING_KEY")
              (gsettings-apply!
               (list %k-restore
                     (gsettings-setting
                      (schema "org.gnome.TextEditor")
                      (key "show-line-numbers")
                      (value "true"))))
              (and (gs-log-contains? "dconf load /")
                   (string=?
                    (call-with-input-file %gs-dconf-stdin
                                          (lambda (p) (read-string p)))
                    "[org/gnome/TextEditor]\nrestore-session=false\nshow-line-numbers=true\n"))))

(test-assert "apply: fails loud on missing-schema"
             (begin
              (gs-reset-log!)
              (setenv "GS_FAKE_MISSING_SCHEMA" "org.gnome.TextEditor")
              (catch #t
                (lambda () (gsettings-apply! (list %k-restore)) #f)
                (lambda args
                  (string-contains (format #f "~s" args)
                                   "schema not found")))))

(test-assert "apply: fails loud on invalid-desired-value"
             (begin
              (unsetenv "GS_FAKE_MISSING_SCHEMA")
              (setenv "GS_FAKE_KEYS" "restore-session\n")
              (setenv "GS_FAKE_RANGE_TYPE" "b")
              (let ((bad (gsettings-setting
                          (schema "org.gnome.TextEditor")
                          (key "restore-session")
                          (value "notabool"))))
                (catch #t
                  (lambda () (gsettings-apply! (list bad)) #f)
                  (lambda args
                    (string-contains (format #f "~s" args)
                                     "invalid desired value"))))))

(test-assert "status/plan never invoke dconf (read-only half of the dry-run contract)"
             (begin
              (gs-reset-log!)
              (unsetenv "GS_FAKE_MISSING_SCHEMA")
              (setenv "GS_FAKE_KEYS" "restore-session\n")
              (setenv "GS_FAKE_GET_VALUE" "true")
              (gsettings-status (list %k-restore))
              (gsettings-plan (list %k-restore))
              (not (gs-log-contains? "dconf"))))

(test-equal "apply: empty declaration set is a no-op without dconf"
            #t
            (begin
             (gs-reset-log!)
             (let ((result (gsettings-apply! '())))
               (and result (not (gs-log-contains? "dconf"))))))

(test-end)

;; 恢复环境。
(setenv "PATH" %gs-original-path)
(false-if-exception (delete-file-recursively %gs-dir))
