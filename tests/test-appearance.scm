;;; 桌面外观测试：apps/gtk、apps/xsettingsd、(guixcfg home
;;; appearance)。
;;;
;;; 覆盖：
;;;   - 事实值 = pinned 构建产物实测主题名（不凭包名猜）；
;;;   - settings.ini/gtk.css 内容与 ownership 约束（GTK4 无
;;;     gtk-theme-name；无 gtk-xft-*/gtk-im-module/
;;;     gtk-application-prefer-dark-theme）；
;;;   - appearance-sync 真实执行（materialize 后跑——AGENT.md §3
;;;     runtime smoke）：mode 校验、runtime xsettingsd.conf 重建、
;;;     pidfile SIGHUP 精确寻址、无 gsettings/bus 时 warn-and-
;;;     continue；
;;;   - xsettingsd-session wrapper 真实执行：reconcile → pidfile →
;;;     exec xsettingsd（无 X 时连接失败 fail visible）。
;;;
;;; 网络：无（gsettings 从 PATH 移除以走降级路径）。

(use-modules (guix store)           ; open-connection
             (guix monads)          ; run-with-store
             (guix gexp)            ; lower-object
             (guix derivations)    ; derivation->output-path
             (guix packages)        ; package-name
             (guix build utils)     ; mkdir-p、delete-file-recursively
             (gnu services)         ; service-value
             (ice-9 rdelim)         ; read-string
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64)
             (guixcfg home appearance)
             (guixcfg apps model)   ; application-home-services
             (guixcfg apps gtk definition)
             (guixcfg apps xsettingsd definition))

(test-runner-current (test-runner-simple))

(test-begin "appearance")

(define %store (open-connection))

(define (read-file p)
  (call-with-input-file p (lambda (port) (read-string port))))

(define %tmp-root
  (string-append (or (getenv "TMPDIR") "/tmp") "/guixcfg-appearance-test"))

;; 隔离环境污染：run-tests 在同一 repl 进程加载全部测试文件，
;; setenv 会泄漏——保存并在结束时恢复。
(define %saved-env
  (map (lambda (v) (cons v (getenv v)))
       '("XDG_RUNTIME_DIR" "PATH" "DISPLAY")))

(define (cleanup!)
  (false-if-exception (delete-file-recursively %tmp-root)))

;; ── 1. 共享事实 = 实测主题名 ──────────────────────────────
(test-equal "facts: gtk light theme" "adw-gtk3" %appearance-gtk-theme-light)
(test-equal "facts: gtk dark theme" "adw-gtk3-dark" %appearance-gtk-theme-dark)
(test-equal "facts: icon theme" "Fluent-light" %appearance-icon-theme)
(test-equal "facts: cursor theme" "Fluent-dark-cursors" %appearance-cursor-theme)
(test-equal "facts: cursor size" 24 %appearance-cursor-size)
(test-equal "facts: default mode" 'light %appearance-default-mode)

;; ── 2. 静态文件内容（lower 后读 store）─────────────────────
(define (lower-text file-like)
  (read-file (run-with-store %store (lower-object file-like))))

(define (materialize file-like)
  "program-file 的 lowering 产物是 derivation——构建后取输出路径
（gexp->script 输出本身可执行，AGENT.md §9）。"
  (let ((drv (run-with-store %store (lower-object file-like))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define (home-files-entry app target)
  "从 APP 的 home-files 贡献中取 TARGET 的 file-like。"
  (let loop ((svcs (application-home-services app)))
    (if (null? svcs)
      #f
      (let ((entry (assoc target (service-value (car svcs)))))
        (if entry
          (cadr entry)
          (loop (cdr svcs)))))))

(define %gtk3-ini (lower-text (home-files-entry %gtk ".config/gtk-3.0/settings.ini")))
(define %gtk4-ini (lower-text (home-files-entry %gtk ".config/gtk-4.0/settings.ini")))
(define %gtk-css  (lower-text (home-files-entry %gtk ".config/gtk-3.0/gtk.css")))

(test-assert "gtk3 settings: theme/icon/cursor/size/font"
             (and (string-contains %gtk3-ini "gtk-theme-name=adw-gtk3")
                  (string-contains %gtk3-ini "gtk-icon-theme-name=Fluent-light")
                  (string-contains %gtk3-ini "gtk-cursor-theme-name=Fluent-dark-cursors")
                  (string-contains %gtk3-ini "gtk-cursor-theme-size=24")
                  (string-contains %gtk3-ini "gtk-font-name=Sans Serif 11")))

(test-assert "gtk4 settings: icon/cursor/size/font, no gtk-theme-name"
             (and (string-contains %gtk4-ini "gtk-icon-theme-name=Fluent-light")
                  (string-contains %gtk4-ini "gtk-font-name=Sans Serif 11")
                  (not (string-contains %gtk4-ini "gtk-theme-name"))))

(test-assert "no forbidden keys anywhere"
             (not (any (lambda (bad)
                         (or (string-contains %gtk3-ini bad)
                             (string-contains %gtk4-ini bad)))
                       '("gtk-xft-" "gtk-im-module"
                                    "gtk-application-prefer-dark-theme"))))

(test-equal "gtk.css is exactly the noctalia.css import"
            "@import url(\"noctalia.css\");\n"
            %gtk-css)

(test-assert "gtk4 gtk.css shares the same import"
             (eq? (home-files-entry %gtk "gtk-3.0/gtk.css")
                  (home-files-entry %gtk "gtk-4.0/gtk.css")))

;; ── 3. appearance-sync 真实执行 ───────────────────────────
(define %sync-bin (materialize %appearance-sync))

(cleanup!)
;; program-file 的 store 文件名带 hash 前缀——PATH 解析需要精确
;; 命令名，建 bin 目录放同名 symlink。另放一个假 gsettings：把
;; 调用参数追加记录到 $XDG_RUNTIME_DIR/guixcfg/gsettings.log，
;; 用于断言 appearance-sync 写出的完整 GSettings 键集合。
(define %test-bin (string-append %tmp-root "/bin"))
(define (setup-test-bin!)
  (mkdir-p %test-bin)
  (symlink %sync-bin (string-append %test-bin "/appearance-sync"))
  (call-with-output-file (string-append %test-bin "/gsettings")
                         (lambda (p)
                           (display "#!/bin/sh\n" p)
                           (display "mkdir -p \"$XDG_RUNTIME_DIR/guixcfg\"\n" p)
                           (display "echo \"$@\" >> \"$XDG_RUNTIME_DIR/guixcfg/gsettings.log\"\n" p)
                           (display "exit 0\n" p)))
  (chmod (string-append %test-bin "/gsettings") #o755))
(setup-test-bin!)

(define (run-sync . args)
  "在隔离环境执行 appearance-sync：XDG_RUNTIME_DIR=tmp，PATH 只有
测试 bin 目录（含假 gsettings 记录器）。"
  (let ((rt (string-append %tmp-root "/runtime")))
    (mkdir-p rt)
    (setenv "XDG_RUNTIME_DIR" rt)
    (setenv "PATH" %test-bin)
    (apply system* %sync-bin args)))

(define (gsettings-log)
  (let ((f (string-append %tmp-root "/runtime/guixcfg/gsettings.log")))
    (if (file-exists? f) (read-file f) "")))

;; 降级路径：PATH 无 gsettings——warn-and-continue，exit 0。
(define %empty-bin (string-append %tmp-root "/empty-bin"))
(mkdir-p %empty-bin)
(let ((rt (string-append %tmp-root "/runtime")))
  (mkdir-p rt)
  (setenv "XDG_RUNTIME_DIR" rt)
  (setenv "PATH" %empty-bin)
  (test-equal "sync: degraded path (no gsettings) exits 0"
              0 (status:exit-val (system* %sync-bin "light"))))

(test-equal "sync: no args exits 2" 2 (status:exit-val (run-sync)))
(test-equal "sync: bad mode exits 2" 2 (status:exit-val (run-sync "blue")))

(test-equal "sync: light exits 0" 0
            (status:exit-val (run-sync "light")))
(define %light-conf
  (read-file (string-append %tmp-root "/runtime/guixcfg/xsettingsd.conf")))
(test-assert "sync: light xsettingsd.conf content"
             (and (string-contains %light-conf "Net/ThemeName \"adw-gtk3\"")
                  (string-contains %light-conf "Net/IconThemeName \"Fluent-light\"")
                  (string-contains %light-conf "Gtk/CursorThemeName \"Fluent-dark-cursors\"")
                  (string-contains %light-conf "Gtk/CursorThemeSize 24")
                  (string-contains %light-conf "Gtk/FontName \"Sans Serif 11\"")))

;; GSettings 全量键（GTK3-on-Wayland 直读 GSettings；GTK4 经 portal
;; 读同一组——这是图标/光标/字体/主题的实际下发通道）。
(test-assert "sync: light writes full GSettings key set"
             (let ((log (gsettings-log)))
               (and (string-contains log "set org.gnome.desktop.interface color-scheme prefer-light")
                    (string-contains log "set org.gnome.desktop.interface gtk-theme adw-gtk3")
                    (string-contains log "set org.gnome.desktop.interface icon-theme Fluent-light")
                    (string-contains log "set org.gnome.desktop.interface cursor-theme Fluent-dark-cursors")
                    (string-contains log "set org.gnome.desktop.interface cursor-size 24")
                    (string-contains log "set org.gnome.desktop.interface font-name Sans Serif 11"))))

(test-equal "sync: dark exits 0" 0 (status:exit-val (run-sync "dark")))
(test-assert "sync: dark flips Net/ThemeName"
             (string-contains
              (read-file (string-append %tmp-root
                                        "/runtime/guixcfg/xsettingsd.conf"))
              "Net/ThemeName \"adw-gtk3-dark\""))
(test-assert "sync: dark writes dark GSettings keys"
             (let ((log (gsettings-log)))
               (and (string-contains log "color-scheme prefer-dark")
                    (string-contains log "gtk-theme adw-gtk3-dark"))))

;; pidfile SIGHUP：fork 一个 sleep 子进程作为受控目标——SIGHUP 的
;; 默认动作是终止，子进程死亡即证明信号精确送达（非 killall）。
;; 有界 WNOHANG 轮询回收（最多 ~5s），未送达则 SIGTERM 清理并记失败。
(define %child-pid (primitive-fork))
(when (= %child-pid 0)
  (sleep 300)
  (primitive-exit 0))
(call-with-output-file (string-append %tmp-root "/runtime/guixcfg/xsettingsd.pid")
                       (lambda (port) (display %child-pid port)))
(run-sync "light")
(define %child-reaped
  (let loop ((tries 50))
    (let ((w (waitpid %child-pid WNOHANG)))
      (cond ((= (car w) %child-pid) w)
        ((zero? tries)
         (kill %child-pid SIGTERM)
         (waitpid %child-pid)
         #f)
        (else (usleep 100000) (loop (- tries 1)))))))
(test-assert "sync: SIGHUP terminates pidfile target (precise reload)"
             %child-reaped)
(test-equal "sync: terminating signal is SIGHUP" SIGHUP
            (and %child-reaped (status:term-sig (cdr %child-reaped))))

;; 死 PID（stale pidfile）不报错。
(call-with-output-file (string-append %tmp-root "/runtime/guixcfg/xsettingsd.pid")
                       (lambda (port) (display %child-pid port))) ; 上面子进程已死
(test-equal "sync: stale pidfile tolerated" 0
            (status:exit-val (run-sync "light")))

;; ── 4. xsettingsd-session wrapper 真实执行 ────────────────
(define %wrapper-bin (materialize %xsettingsd-session-wrapper))

(cleanup!)
;; cleanup 删掉了 %tmp-root（含 %test-bin 内容）——重建。
(setup-test-bin!)
(let ((rt (string-append %tmp-root "/runtime")))
  (mkdir-p rt)
  (setenv "XDG_RUNTIME_DIR" rt)
  (setenv "PATH" %test-bin)      ; appearance-sync 经同名 symlink 解析
  (setenv "DISPLAY" ":99"))     ; 跳过有界等待；xsettingsd 连接必败
(define %wrapper-status (system* %wrapper-bin))
(test-assert "wrapper: execs xsettingsd (fails on unreachable X)"
             (not (zero? (status:exit-val %wrapper-status))))
(test-assert "wrapper: reconcile wrote runtime xsettingsd.conf"
             (string-contains
              (read-file (string-append %tmp-root
                                        "/runtime/guixcfg/xsettingsd.conf"))
              "Net/ThemeName \"adw-gtk3\""))
(test-assert "wrapper: pidfile written with numeric pid"
             (integer? (call-with-input-file
                        (string-append %tmp-root "/runtime/guixcfg/xsettingsd.pid")
                        read)))

;; ── 5. noctalia seed：GTK 模板窄 hook 接线 ────────────────
(define %seed (read-file "modules/guixcfg/apps/noctalia-git/base-settings.toml"))
(test-assert "seed: builtin gtk3/gtk4 removed"
             (not (string-contains %seed "\"gtk3\"")))
(test-assert "seed: user templates wired with narrow post-hook"
             (and (string-contains %seed "[theme.templates.user.gtk3]")
                  (string-contains %seed "[theme.templates.user.gtk4]")
                  (string-contains %seed
                                   "post_hook = \"appearance-sync {{ mode }}\"")))
(test-assert "seed: outputs are gtk-{3,4}/noctalia.css"
             (and (string-contains %seed
                                   "output_path = \"$XDG_CONFIG_HOME/gtk-3.0/noctalia.css\"")
                  (string-contains %seed
                                   "output_path = \"$XDG_CONFIG_HOME/gtk-4.0/noctalia.css\"")))

;; ── 6. niri spawn 与 cursor ───────────────────────────────
(define %niri-common (read-file "modules/guixcfg/apps/niri/common.kdl"))
(test-assert "niri: spawns xsettingsd-session wrapper, not raw xsettingsd"
             (and (string-contains %niri-common
                                   "spawn-at-startup \"xsettingsd-session\"")
                  (not (string-contains %niri-common
                                        "spawn-at-startup \"xsettingsd\""))))
(test-assert "niri: cursor block matches facts"
             (and (string-contains %niri-common
                                   "xcursor-theme \"Fluent-dark-cursors\"")
                  (string-contains %niri-common "xcursor-size 24")))

(cleanup!)
(for-each (lambda (pair)
            (if (cdr pair)
              (setenv (car pair) (cdr pair))
              (unsetenv (car pair))))
          %saved-env)
(test-end "appearance")
