;;; onlyoffice application unit：ONLYOFFICE Desktop Editors（virelith
;;; channel 官方 Linux x64 二进制重打包）+ bwrap 字体投影 adapter。
;;;
;;; 包来源：(virelith packages onlyoffice) 的 onlyoffice-desktopeditors
;;; ——ELF interpreter/RUNPATH/launcher 环境（QT_QPA_PLATFORM=xcb、
;;; GStreamer、PATH）全部归 channel 包层；本模块不复制、不修补。
;;;
;;; 持久化边界（宿主实装实证 2026-08）：
;;;   ~/.config/onlyoffice/       DesktopEditors.conf 等偏好
;;;   ~/.local/share/onlyoffice/  recents/templates/recover（autosave）/
;;;                               data（词典、字体 DB 缓存）/sdkjs-plugins
;;;   ~/.cache/onlyoffice/ 不存在于宿主实装——不持久化。
;;;
;;; 字体投影（本模块私有 adapter 存在的理由；审计链）：
;;;   1. ONLYOFFICE 编辑器字体库由自有 scanner 建立（不走
;;;      fontconfig），其目录 walker 按 readdir d_type 过滤：
;;;      DT_DIR 递归、DT_REG 收集、**DT_LNK 忽略**——Guix profile
;;;      与 XDG 字体农场都是 symlink 树，不能作为其字体源；
;;;   2. scanner 硬编码扫描 /usr/share/fonts 与
;;;      /usr/local/share/fonts（9.4.0 二进制 libgraphics.so
;;;      实证），Guix 宿主两者皆无；
;;;   3. 因此 adapter 把 ONLYOFFICE 启动进一个 bwrap mount
;;;      namespace：--bind / / 完整继承宿主视图（recursive——
;;;      /home、/persist 等子挂载自然可见），/usr 用
;;;      --overlay-src + --tmp-overlay 覆盖为私有 overlay
;;;      （宿主 /usr 为 lower，tmpfs 为 upper/work——宿主零污染，
;;;      进程退出即消亡），在其中 /usr/local/share/fonts/<pkg>
;;;      逐个 ro-bind 各字体包的真实 share/fonts 目录（零复制、
;;;      真 DT_DIR/DT_REG）；
;;;   4. --dev-bind /dev /dev 不是多余项：--bind / / 的普通 bind
;;;      带 MS_NODEV（bwrap bind-mount.c 的 flags 逻辑），不重挂
;;;      /dev 连 /dev/null 都不可写（终审实测）；
;;;   5. CUSTOM_FONTS_PATH 只经 bwrap --setenv 存在于该进程树
;;;      （scanner 双保险；不进 session 环境）；
;;;   6. 必须继续 exec virelith launcher（runtime integration 归
;;;      channel），adapter 只是 mount namespace 适配层；
;;;   7. fail-closed：namespace 建立失败则启动失败，不回退裸启动；
;;;   8. removal condition：ONLYOFFICE scanner 改用 fontconfig 或
;;;      开始跟随 symlink——届时删除整个 adapter，直接安装
;;;      virelith 包。
;;;
;;; bwrap 在此只做 mount namespace + 路径投影，不是安全 sandbox：
;;; 不加 --unshare-*/seccomp/只读根等任何额外策略；--bind / / 保持
;;; 与裸运行时一致的宿主权限（设计目标）。bubblewrap 是普通
;;; non-setuid 包（pinned Guix 定义无 setuid 处理；--overlay-src
;;; 在 setuid 模式下被 bwrap 禁止，non-setuid 是结构性前提）。

(define-module (guixcfg apps onlyoffice definition)
               #:use-module (virelith packages onlyoffice) ; onlyoffice-desktopeditors
               #:use-module (gnu packages virtualization)  ; bubblewrap
               #:use-module (gnu packages bash)            ; bash-minimal
               #:use-module (gnu packages fontutils)       ; fontconfig（无 share/fonts，结构性排除）
               #:use-module (guix packages)          ; package、package-name、package-version
               #:use-module (guix build-system trivial)
               #:use-module (guix gexp)              ; gexp、file-append
               #:use-module (guixcfg fonts)          ; %fonts（唯一事实源）
               #:use-module (guixcfg apps model)     ; application
               #:use-module (guixcfg system application-persistence) ; rule
               #:use-module (srfi srfi-1)            ; delete、append-map
               #:export (%onlyoffice))

;; ── 字体 bind 规格（从 %fonts 派生，不复制清单）────────────────
;; %fonts 是唯一事实源；下列 bind 规格基于已完成的结构审计生成：
;; fontconfig 是当前唯一不提供 share/fonts 的包（工具包），作
;; 结构性排除；未来 %fonts 若加入新的非字体树工具包，需同步审计
;; 此处（代码不做运行时/求值期目录存在性检查）。
(define %onlyoffice-font-bind-specs
  (map (lambda (pkg)
         (list (package-name pkg)
               (file-append pkg "/share/fonts")
               (string-append "/usr/local/share/fonts/"
                              (package-name pkg))))
       (delete fontconfig %fonts)))

;; bwrap argv（顺序是契约，见头部注释 3/4）：
;;   --bind / /            宿主视图（recursive，子挂载继承）
;;   --dev-bind /dev /dev  撤销 --bind 的 MS_NODEV（设备访问）
;;   --overlay-src /usr --tmp-overlay /usr
;;                         宿主 /usr=lower + 私有 tmpfs upper/work
;;   --dir …               虚拟字体根（overlay upper，namespace 私有）
;;   每包 --ro-bind         真实字体目录（零复制）
;;   --setenv              CUSTOM_FONTS_PATH 只进该进程树
(define %onlyoffice-bwrap-argv
  (append
   (list "--bind" "/" "/"
         "--dev-bind" "/dev" "/dev"
         "--overlay-src" "/usr" "--tmp-overlay" "/usr"
         "--dir" "/usr/local/share/fonts")
   (append-map (lambda (spec)
                 (list "--ro-bind" (cadr spec) (caddr spec)))
               %onlyoffice-font-bind-specs)
   (list "--setenv" "CUSTOM_FONTS_PATH" "/usr/local/share/fonts")))

;; ── 私有 adapter package ─────────────────────────────────────
;; profile 只装 adapter（base 包不进 profile——desktop/bin 冲突）：
;;   bin/onlyoffice-desktopeditors   bwrap wrapper（exec virelith
;;                                   launcher；store 路径全部 build
;;                                   期固化，不做运行时 profile 查询）
;;   share/applications/…desktop     base desktop 原样复制，只把
;;                                   base launcher 路径换成 wrapper
;;                                   （主 Exec / TryExec / 4 个
;;                                   new-document action 一次替换）
;;   share/icons                     base icons 的 symlink tree
;;                                   （union-build；零复制）
;; base 包、bubblewrap、字体包经 gexp 引用进入 derivation inputs 与
;; 输出 references——GC closure 完整，字体包 bump 触发 adapter 重建。
(define onlyoffice-adapter
  (package
   (name "onlyoffice-desktopeditors-adapter")
   (version (package-version onlyoffice-desktopeditors))
   (source #f)
   (build-system trivial-build-system)
   (arguments
    (list
     #:modules '((guix build utils)
                 (guix build union)
                 (ice-9 regex))       ; regexp-quote
     #:builder
     #~(begin
        (use-modules (guix build utils)
                     (guix build union)
                     (ice-9 regex))
        (let* ((out (assoc-ref %outputs "out"))
               (bin (string-append out "/bin"))
               (wrapper (string-append bin "/onlyoffice-desktopeditors"))
               (apps (string-append out "/share/applications"))
               (icons (string-append out "/share/icons"))
               (base-desktop
                (string-append #$onlyoffice-desktopeditors
                               "/share/applications/onlyoffice-desktopeditors.desktop"))
               (base-launcher
                (string-append #$onlyoffice-desktopeditors
                               "/bin/onlyoffice-desktopeditors")))
          (mkdir-p bin)
          (mkdir-p apps)
          ;; wrapper：每个 argv 一行（路径均无空格，无需转义）。
          (call-with-output-file wrapper
            (lambda (port)
              (format port "#!~a~%" #$(file-append bash-minimal "/bin/bash"))
              (format port "exec ~a \\\n"
                      #$(file-append bubblewrap "/bin/bwrap"))
              (for-each (lambda (arg) (format port "  ~a \\\n" arg))
                        (list #$@%onlyoffice-bwrap-argv))
              (format port "  -- ~a \"$@\"~%" base-launcher)))
          (chmod wrapper #o755)
          ;; desktop entry：复制 base 后把 base launcher 路径换成
          ;; wrapper（主 Exec / TryExec / 4 个 new-document action
          ;; 一次替换覆盖；%U、--new:* 等参数原样保留）。pattern 经
          ;; regexp-quote 字面化，避免 store basename 里的版本号
          ;; 字符（. 等）被当 regexp 解释。
          (let ((desktop-out
                 (string-append apps "/onlyoffice-desktopeditors.desktop")))
            (copy-file base-desktop desktop-out)
            (substitute* desktop-out
              (((regexp-quote base-launcher)) wrapper)))
          ;; icons：base 图标树的 per-file symlink（union-build）。
          (union-build icons
                       (list (string-append #$onlyoffice-desktopeditors
                                            "/share/icons")))))
     ))
   (inputs (list onlyoffice-desktopeditors bubblewrap bash-minimal))
   (supported-systems '("x86_64-linux"))
   (home-page "https://www.onlyoffice.com/desktop.aspx")
   (synopsis "ONLYOFFICE Desktop Editors with namespaced font projection")
   (description
    "Adapter around the virelith onlyoffice-desktopeditors package: launches
the upstream launcher inside a bubblewrap mount namespace that projects the
Guix font packages as real directories under /usr/local/share/fonts (its
built-in font scanner skips symlinks and never consults fontconfig).")
   (license (package-license onlyoffice-desktopeditors))))

(define %onlyoffice
  (application
   (name 'onlyoffice)
   (home-packages (list onlyoffice-adapter))
   ;; 无 system-services/home-services：挂载全部发生在 per-launch
   ;; namespace 内，宿主零状态。
   (persistence
    (list (application-persistence-rule
           (name 'config)
           (backing "onlyoffice/config")          ; backing root 相对
           (consumer ".config/onlyoffice")        ; DesktopEditors.conf 等
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'share)
           (backing "onlyoffice/share")           ; 词典/插件/recover/字体 DB
           (consumer ".local/share/onlyoffice")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
