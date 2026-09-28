;;; Google Chrome application unit：官方 Chrome stable 二进制 +
;;; Chromium User Data Directory 持久化边界（docs/architecture/
;;; persistence.md production consumers）。
;;;
;;; 来源（pinned nonguix 653504e6 审计）：google-chrome-stable
;;; 定义于 (nongnu packages chrome)（不是 chromium.scm 的
;;; chromium-embedded-framework）；v151.0.7922.75-1，
;;; chromium-binary-build-system（nonguix 官方 wrapper：/bin/
;;; google-chrome-stable + CHROME_WRAPPER + .desktop 安装），
;;; #:substitutable? #f（Google 服务器直下 deb，不经 substitutes）；
;;; supported-systems 仅 x86_64-linux。Chrome bundles Qt 5/6 shims but the
;;; pinned package does not include their Wayland platform plugins.  Add both
;;; plugin sets to Chrome's own wrapper; Chromium's Ozone backend remains
;;; independent.
;;;
;;; 持久化边界（决策已定，不做 profile 内部细分）：
;;;   - 持久化：~/.config/google-chrome/ 整体（Chromium 官方 User
;;;     Data Directory；Cookies/History/Extensions/IndexedDB/Local
;;;     Storage/Service Worker/ShaderCache 等一律随目录走）；
;;;   - 不持久化：~/.cache/google-chrome/（ephemeral，重启重建）；
;;;   - 不新增 ~/.pki/nssdb 持久化（证书/NSS 状态归未来独立证书
;;;     基础设施，Chrome 不拥有）；程序文件在 store/profile，非
;;;     持久状态。
;;;
;;; Keyring（已实现，不改）：Chrome 经 D-Bus 自动使用现有
;;; org.freedesktop.secrets（既有 Secret Service 会话服务；login
;;; collection 会话启动即解锁，见 docs/architecture/
;;; desktop-authentication.md）。默认 password store 自动探测：
;;; Secret Service 可用即正常使用，不需要 basic 回退模式；Chrome
;;; 凭据落入既有 keyrings vault（gnome-keyring app 自己的
;;; persistence rule 持久化）——本模块不产生第二套 secret storage。
;;;
;;; 桌面集成（既有会话已满足，无新增）：.desktop 文件经 profile
;;; share/applications 进 XDG_DATA_DIRS（应用启动器自动发现）；Wayland
;;; 原生，X11 fallback 走 xwayland-satellite（会话已有）；字体由包
;;; 自带 + font-liberation input。默认参数运行，不加 Chromium flags。
;;;
;;; 职责边界（AGENT.md §Application layer）：本模块只描述“Chrome
;;; 是什么”——package、User Data 持久化、desktop entry 纯数据常量
;;; （%chrome-desktop-entry）。“Chrome 是否被选作默认浏览器”是
;;; 用户级策略，属于统一 XDG/default-apps 模块 (guixcfg home xdg)：
;;; 它消费 %chrome-desktop-entry 生成 $XDG_CONFIG_HOME/mimeapps.list
;;; （derived state，不持久化）。依赖方向 policy → app metadata，
;;; 本模块不反向依赖 xdg。

(define-module (guixcfg apps google-chrome-stable definition)
                #:use-module (nongnu packages chrome)   ; google-chrome-stable
                #:use-module (guix gexp)                 ; #~ / #$ / computed-file
                #:use-module (guix records)
                #:use-module (guix packages)
                #:use-module (guix utils)                ; substitute-keyword-arguments
                #:use-module (gnu home services)         ; home-files-service-type
                #:use-module (gnu packages qt)           ; qtwayland / qtwayland-5
                #:use-module (gnu services)              ; simple-service
               #:use-module (guixcfg apps model)       ; application
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%google-chrome-stable
                         %chrome-desktop-entry))

;; Chrome stable 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实；nonguix patch-assets 阶段会重写其 Exec
;; 指向 wrapper）。纯数据常量：供统一 XDG 策略模块引用，不在此决定
;; 默认应用。
(define %chrome-desktop-entry "google-chrome.desktop")

(define google-chrome-stable/fixed
  (package/inherit
   google-chrome-stable
   (inputs
    `(("qtwayland-6" ,qtwayland)
      ("qtwayland-5" ,qtwayland-5)
      ,@(package-inputs google-chrome-stable)))
   (arguments
    (substitute-keyword-arguments (package-arguments google-chrome-stable)
      ((#:phases phases)
       #~(modify-phases #$phases
           ;; This applies only to Chrome's optional Qt integration shims, not
           ;; to Chromium's Ozone Wayland backend.
           (add-after 'install-wrapper 'add-qt-wayland-plugins
             (lambda _
               (wrap-program (string-append #$output "/bin/google-chrome")
                 `("QT_PLUGIN_PATH" ":" prefix
                   (,(string-append #$(this-package-input "qtwayland-6")
                                    "/lib/qt6/plugins")
                    ,(string-append #$(this-package-input "qtwayland-5")
                                     "/lib/qt5/plugins"))))))))))))

;; nonguix 的 patch-assets 用 ("^Exec=.*") -> "Exec=<wrapper>" 重写
;; desktop entry 的**每一行** Exec，抹掉了上游的字段码 %U 和
;; action 参数（nongnu/packages/chrome.scm）。结果是任何经 GIO 桌面
;; entry 启动的路径（g_app_info_launch_default_for_uri：xdg-open 的
;; gio 分支、xdg-desktop-portal 的 OpenURI 后端——Flatpak 应用点击
;; 链接即走此路）都只启动 Chrome 而**不传 URL**（XDG spec：没有
;; %u/%U/%f/%F 字段码时 launcher 不追加 URI）。
;;
;; 修复：从包自己的 desktop entry 派生一份修正文件，恢复上游 Exec
;; 字段码（主 Exec 带 %U；new-private-window action 带 --incognito），
;; 经 XDG_DATA_HOME（~/.local/share/applications，优先级高于
;; XDG_DATA_DIRS 的 profile 条目）投影覆盖。derived from package
;; output，所以随 Chrome 升级自动跟随，且**不需要重建 Chrome**。
(define %chrome-desktop-entry-shadow
  (computed-file
   "google-chrome-desktop-shadow.desktop"
   #~(begin
       (use-modules (ice-9 rdelim))
       (define source
         #$(file-append google-chrome-stable/fixed
                        "/share/applications/google-chrome.desktop"))
       (define exe
         #$(file-append google-chrome-stable/fixed "/bin/google-chrome"))
       (define (exec-line section)
         (cond ((string=? section "[Desktop Entry]")
                (string-append "Exec=" exe " %U"))
               ((string-contains section "new-private-window")
                (string-append "Exec=" exe " --incognito"))
               (else (string-append "Exec=" exe))))
       (call-with-output-file #$output
         (lambda (out)
           (call-with-input-file source
             (lambda (in)
               (let loop ((section ""))
                 (let ((line (read-line in)))
                   (unless (eof-object? line)
                     (cond ((string-prefix? "[" line)
                            (display line out) (newline out)
                            (loop line))
                           ((string-prefix? "Exec=" line)
                            (display (exec-line section) out) (newline out)
                            (loop section))
                           (else
                            (display line out) (newline out)
                            (loop section)))))))))))))

(define %google-chrome-stable
  (application
   (name 'google-chrome-stable)
   (home-packages (list google-chrome-stable/fixed))
   (home-services
    (list (simple-service 'google-chrome-desktop-shadow
                          home-files-service-type
                          `((".local/share/applications/google-chrome.desktop"
                             ,%chrome-desktop-entry-shadow)))))
   (persistence
    (list (application-persistence-rule
           (name 'user-data)
           (backing "google-chrome-stable/user-data") ; backing root 相对（persistence.md）
           (consumer ".config/google-chrome")         ; HOME 相对（官方 User Data）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
