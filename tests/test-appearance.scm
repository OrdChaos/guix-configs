;;; 桌面外观测试：apps/gtk、(guixcfg home appearance)。
;;;
;;; 覆盖：
;;;   - 事实值 = pinned 构建产物实测主题名（不凭包名猜）；
;;;   - settings.ini/gtk.css 内容与 ownership 约束（GTK4 无
;;;     gtk-theme-name；无 gtk-xft-*/gtk-im-module/
;;;     gtk-application-prefer-dark-theme）；
;;;   - appearance-sync 真实执行（materialize 后跑——AGENT.md §3
;;;     runtime smoke）：mode 校验、GSettings 全量键写入、无
;;;     gsettings/bus 时 warn-and-continue。
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
             (guixcfg apps gtk definition))

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
  "从 APP 的 home-files 贡献中取 TARGET 的 file-like（跳过非
home-files 的 service：它们的 service-value 不是 (target . file) 表）。"
  (let loop ((svcs (application-home-services app)))
    (if (null? svcs)
      #f
      (let* ((value (service-value (car svcs)))
             (entry (and (list? value)
                         (every pair? value)
                         (assoc target value))))
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
测试 bin 目录（含假 gsettings 记录器）。guixcfg 目录由测试自建
（假 gsettings 只负责追加日志）。"
  (let ((rt (string-append %tmp-root "/runtime")))
    (mkdir-p rt)
    (mkdir-p (string-append rt "/guixcfg"))
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
(test-assert "sync: dark writes dark GSettings keys"
             (let ((log (gsettings-log)))
               (and (string-contains log "color-scheme prefer-dark")
                    (string-contains log "gtk-theme adw-gtk3-dark"))))

;; ── 4. noctalia seed：GTK 模板窄 hook 接线 ────────────────
(define %seed (read-file "modules/guixcfg/apps/noctalia/base-settings.toml"))
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

(cleanup!)
(for-each (lambda (pair)
            (if (cdr pair)
              (setenv (car pair) (cdr pair))
              (unsetenv (car pair))))
          %saved-env)
(test-end "appearance")
