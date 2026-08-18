;;; M2 graphical-session 环境测试（session environment / executable
;;; discovery；docs/architecture/graphics.md）。
;;;
;;; 覆盖：
;;;   PATH1  launcher 是唯一环境构造点（desktop.scm 一个 setenv PATH）
;;;   PATH2  Guix Home 可执行命名空间（~/.guix-home/profile/bin）包含
;;;   PATH3  system 可执行命名空间（/run/current-system/profile/bin）包含
;;;   PATH4  不依赖 shell rc / login shell
;;;   PATH5/6 niri 及其 spawn 的程序继承同一环境（setenv 在 execl 前）
;;;   PATH7  无 FHS /usr/bin workaround
;;;   DB1    dbus-run-session 是显式 bootstrap 依赖（store 引用）
;;;   DB2    dbus-daemon 显式引用（--dbus-daemon=<store>）
;;;   DB3    无 /usr/bin/dbus-daemon
;;;   DB4    单一 session bus owner（一个 dbus-run-session）
;;;   DB5    隔离 smoke：dbus-run-session 在构造 PATH 下解析 dbus-daemon
;;;          （无交互 shell profile）
;;;   X1     xwayland-satellite 在 Home profile
;;;   X3     niri config 无重复 spawn（xwayland-satellite 由 niri 经
;;;          PATH 自动发现；不显式 spawn）
;;;   O1     会话内服务（mako/polkit/pipewire/wireplumber）在 niri
;;;          config 中单 owner（各 ≤1 次 spawn）
;;;
;;; 不启动 niri；DB5 的 smoke 在完全隔离的临时环境运行。

(use-modules (guixcfg system desktop)
             (guixcfg home packages)
             (guix gexp)
             (guix store)
             (guix monads)
             (guix derivations)
             (guix packages)      ; package-derivation
             (gnu packages glib)       ; dbus
             (gnu packages window-management) ; niri
             (gnu packages xorg)       ; xwayland-satellite
             (ice-9 popen)      ; open-pipe*
             (ice-9 rdelim)     ; read-line、read-string
             (ice-9 textual-ports) ; get-string-all
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %store (open-connection))

(define (launcher-text)
  "niri-wayland-session 的 gexp 源码文本（write 输出，含字符串字面量）。"
  (call-with-output-string
   (lambda (p) (write (program-file-gexp niri-wayland-session) p))))

(define (launcher-references)
  "launcher gexp 引用的 file-like 列表（gexp-references 未从
(guix gexp) 导出，经模块内绑定访问）。"
  ((@ (guix gexp) gexp-references)
   (program-file-gexp niri-wayland-session)))

(define (has-file-append refs base suffix)
  "REFS 中是否有 (file-append BASE SUFFIX...)。gexp-references 返回
gexp-input 包装，先解包。"
  (any (lambda (r)
         (let ((thing (if (gexp-input? r)
                        ((@ (guix gexp) gexp-input-thing) r)
                        r)))
           (and (file-append? thing)
                (eq? (file-append-base thing) base)
                (equal? (file-append-suffix thing) suffix))))
       refs))

(test-begin "session-env")

;; ── PATH1：唯一环境构造点 ──────────────────────────────────
(test-assert "PATH1: single authoritative PATH construction in desktop.scm"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (let loop ((i 0) (n 0))
                 (let ((m (string-contains s "setenv \"PATH\"" i)))
                   (if m (loop (+ m 1) (+ n 1)) (= n 1))))))

;; ── PATH2/3/4/7：构造内容 ──────────────────────────────────
(test-assert "PATH2: Home profile executable namespace included"
             (string-contains (launcher-text) ".guix-home/profile/bin"))

(test-assert "PATH3: system profile executable namespace included"
             (string-contains (launcher-text)
                              "/run/current-system/profile/bin"))

(test-assert "PATH4: no login shell / shell rc dependency"
             (let ((t (launcher-text)))
               (not (or (string-contains t "bash -l")
                        (string-contains t "source ~/.profile")
                        (string-contains t ".bash_profile")
                        (string-contains t ".zprofile")))))

(test-assert "PATH7: no FHS /usr/bin workaround"
             (not (string-contains (launcher-text) "/usr/bin")))

;; ── PATH5/6：环境在 exec 前设置（niri 继承）────────────────
(test-assert "PATH5/6: setenv PATH precedes the exec (niri and its spawns inherit)"
             (let ((t (launcher-text))
                   (setenv-pos (string-contains (launcher-text) "setenv \"PATH\""))
                   (exec-pos (string-contains (launcher-text) "execl")))
               (and setenv-pos exec-pos (< setenv-pos exec-pos))))

;; ── DB1/2/3/4：D-Bus bootstrap 显式化 ──────────────────────
(test-assert "DB1: dbus-run-session is an explicit store reference"
             (has-file-append (launcher-references) dbus
                              '("/bin/dbus-run-session")))

(test-assert "DB2: dbus-daemon explicitly referenced (--dbus-daemon=<store>)"
             (and (has-file-append (launcher-references) dbus
                                   '("/bin/dbus-daemon"))
                  (string-contains (launcher-text) "--dbus-daemon=")))

(test-assert "DB3: no /usr/bin/dbus-daemon"
             (not (string-contains (launcher-text) "/usr/bin/dbus-daemon")))

(test-assert "DB4: exactly one dbus-run-session bootstrap reference"
             (let ((refs (filter (lambda (r)
                                   (let ((thing (if (gexp-input? r)
                                                  ((@ (guix gexp) gexp-input-thing) r)
                                                  r)))
                                     (and (file-append? thing)
                                          (eq? (file-append-base thing) dbus)
                                          (equal? (file-append-suffix thing)
                                                  '("/bin/dbus-run-session")))))
                                 (launcher-references))))
               (= 1 (length refs))))

;; ── X1/X3：xwayland-satellite 单 owner ─────────────────────
(test-assert "X1: xwayland-satellite present in Home packages"
             (memq xwayland-satellite %home-packages))

(test-assert "X3: niri config does not spawn xwayland-satellite (niri discovers via PATH)"
             (let ((s (call-with-input-file "files/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "xwayland-satellite"))))

;; ── O1：会话服务单 owner（niri spawn ≤1 次）────────────────
(define %session-services
  '("mako" "lxpolkit" "pipewire" "wireplumber"))

(test-assert "O1: each session service spawned at most once in niri config"
             (let ((s (call-with-input-file "files/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (every (lambda (svc)
                        (let loop ((i 0) (n 0))
                          (let ((m (string-contains s svc i)))
                            (if m (loop (+ m 1) (+ n 1)) (<= n 1)))))
                      %session-services)))

;; ── DB5：隔离 smoke——dbus-run-session 在构造 PATH 下解析 ──
;; 用 store 的 dbus（构建/下载一次）；完全隔离的临时 HOME/XDG_RUNTIME_DIR。
(test-assert "DB5: dbus-run-session resolves dbus-daemon in isolated env"
             (let* ((dbus-drv (package-derivation %store dbus #:graft? #f))
                    (dbus-avail (begin
                                  (build-derivations %store (list dbus-drv))
                                  #t))
                    (dbus-dir (derivation->output-path dbus-drv))
                    (dbus-run (string-append dbus-dir "/bin/dbus-run-session"))
                    (dbus-daemon (string-append dbus-dir "/bin/dbus-daemon"))
                    (tmp (mkdtemp "/tmp/guixcfg-session-XXXXXX"))
                    (home (string-append tmp "/home"))
                    (xdg (string-append tmp "/run")))
               (dynamic-wind
                (lambda () #t)
                (lambda ()
                  (mkdir home)
                  (mkdir xdg)
                  (chmod xdg #o700)  ; dbus 要求 XDG_RUNTIME_DIR 0700
                  ;; 无 shell rc、无 login shell；PATH 完全受控
                  ;; （launcher 构造的语义：Home bin + system bin，
                  ;;  这里 smoke 只给 dbus-dir/bin 验证解析）。
                  (let ((pipe (open-pipe*
                               OPEN_READ
                               "env"
                               (string-append "HOME=" home)
                               (string-append "XDG_RUNTIME_DIR=" xdg)
                               (string-append "PATH=" dbus-dir "/bin")
                               dbus-run
                               (string-append "--dbus-daemon=" dbus-daemon)
                               "--" "/bin/sh" "-c"
                               "test -n \"$DBUS_SESSION_BUS_ADDRESS\"")))
                    (let ((code (status:exit-val (close-pipe pipe))))
                      (zero? code))))
                (lambda ()
                  (false-if-exception (delete-file-recursively tmp))))))

;; ── PATH helpers：去重行为（执行同一 session-path-helpers gexp）─
(test-assert "PATH helpers: dedupe keeps order and first occurrence"
             (let* ((drv (run-with-store
                           %store
                           (gexp->script
                            "session-path-test"
                            #~(begin
                                #$session-path-helpers
                                (display
                                 (join-colon
                                  (dedupe
                                   (list "/a/bin" "/b/bin" "/a/bin"
                                         "/c/bin" "/b/bin"))))))))
                    (path (begin
                            (build-derivations %store (list drv))
                            (derivation->output-path drv)))
                    (run (begin
                           ;; gexp->script 输出已可执行（#o555）
                           (let ((pipe (open-pipe* OPEN_READ path)))
                             (let ((s (get-string-all pipe)))
                               (close-pipe pipe)
                               s)))))
               (string=? run "/a/bin:/b/bin:/c/bin")))

(test-assert "PATH helpers: split skips empty segments"
             (let* ((drv (run-with-store
                           %store
                           (gexp->script
                            "session-path-test2"
                            #~(begin
                                #$session-path-helpers
                                (display
                                 (join-colon
                                  (dedupe
                                   (split-colon "/a/bin::/b/bin:"))))))))
                    (path (begin
                            (build-derivations %store (list drv))
                            (derivation->output-path drv)))
                    (run (begin
                           ;; gexp->script 输出已可执行（#o555）
                           (let ((pipe (open-pipe* OPEN_READ path)))
                             (let ((s (get-string-all pipe)))
                               (close-pipe pipe)
                               s)))))
               (string=? run "/a/bin:/b/bin")))

;; ── RUNTIME：真实执行 generated launcher（§7/8）────────────
;; materialize launcher → 无 XDG_RUNTIME_DIR 执行：launcher 在 execl
;; 前 error（"XDG_RUNTIME_DIR unset"）——generated runtime 的 PATH
;; 构造（unbound binding 风险所在）被真实 primitive-load 执行。
;; 若再有 delete-duplicates 类 unbound，这里会先报 "Unbound variable"
;; 而不是 XDG 消息。
(test-assert "RUNTIME: launcher primitive-loads; PATH construction has no unbound bindings"
             (let* ((drv (run-with-store %store
                           (lower-object niri-wayland-session)))
                    (script (begin
                              (build-derivations %store (list drv))
                              (derivation->output-path drv)))
                    (shebang (call-with-input-file script
                                                   (lambda (p) (read-line p))))
                    (guile (and (string-prefix? "#!" shebang)
                                (car (string-split (substring shebang 2)
                                                   #\space))))
                    (tmp (mkdtemp "/tmp/guixcfg-session-rt-XXXXXX"))
                    (home (string-append tmp "/home")))
               (dynamic-wind
                (lambda () #t)
                (lambda ()
                  (mkdir home)
                  (let* ((pipe (open-pipe*
                                OPEN_READ "env"
                                "-u" "XDG_RUNTIME_DIR"
                                (string-append "HOME=" home)
                                "sh" "-c"
                                (string-append guile " --no-auto-compile "
                                               script " 2>&1")))
                         (err (get-string-all pipe))
                         (code (status:exit-val (close-pipe pipe))))
                    (and (not (zero? code))
                         (string-contains err "XDG_RUNTIME_DIR unset")
                         (not (string-contains err "Unbound variable")))))
                (lambda ()
                  (false-if-exception (delete-file-recursively tmp))))))

(test-end "session-env")
