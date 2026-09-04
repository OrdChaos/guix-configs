;;; nautilus application unit：GNOME 文件管理器（niri bind Mod+E
;;; spawn "nautilus" "--new-window"）。
;;;
;;; 桌面集成：
;;;   - GLib schemas 随 profile 经 XDG_DATA_DIRS 发现；
;;;   - Wayland 原生，portal 由 niri 会话提供；
;;;   - trash（回收站位置与"移到回收站"）由 gvfs 的 D-Bus daemon
;;;     （org.gtk.vfs.Daemon / gvfsd-trash）提供。nautilus 包把 gvfs
;;;     放在编译期 inputs（非 propagated，不随 nautilus 进 profile）；
;;;     D-Bus activation 按 XDG_DATA_DIRS 扫描 share/dbus-1/services
;;;     ——gvfs 必须显式进 profile 才能激活 trash 后端（pinned
;;;     guix 3dc50d9 审计）。trash 内容持久化属用户数据
;;;     （user-persistence 的 .local/share/Trash，docs/architecture/
;;;     home.md）。
;;;
;;;   - "在此处打开终端"：nautilus-open-any-terminal（virelith 包，
;;;     连同其 nautilus-python 绑定——pinned Guix 无此二者，
;;;     docs/architecture/nautilus-extension 审计）经 XDG_DATA_DIRS
;;;     的 share/nautilus-python/extensions 被 nautilus 加载；终端
;;;     经 gsettings 声明（com.github.stunkymonkey.nautilus-open-any-
;;;     terminal / terminal = ghostty——本仓库唯一 terminal 事实，
;;;     (guixcfg apps ghostty)），schema 随 home profile 投影，
;;;     gsettings reconcile 的 runtime dconf 投影统一应用。
;;;
;;;     Guix 特有断点（2026-09 VM 实测根因）：扩展发现没问题
;;;     （XDG_DATA_DIRS 含 profile share ✓），但 nautilus-python 的
;;;     C loader 内嵌 store 里的裸 python（python-nautilus 的编译期
;;;     input，3.12.x），其 sys.path 不含 profile 的 site-packages
;;;     ——loader/扩展的 `import gi` 静默失败，右键菜单不出现。
;;;     主机 Arch 上同一扩展开箱即用：系统 python 的 gi 在
;;;     dist-packages 默认路径（/usr/lib/python3.x/site-packages）。
;;;     修复：会话级 PYTHONPATH 指向 profile site-packages
;;;     （嵌入式解释器 Py_Initialize 尊重 PYTHONPATH；版本号从
;;;     pinned python 推导，不写死）。代价：会话内所有 python
;;;     都看到该 site-packages——非 3.12 解释器（如编辑器自带）
;;;     只在导入其中 C 模块时才报版本不匹配，正常不用 gi 的
;;;     工具不受影响（2026-09 取舍记录）。
;;;
;;;     重复菜单项（2026-09 VM 实测）：saayix ghostty 包随包分发
;;;     自己的 nautilus-python 扩展 ghostty.py（wezterm 移植，
;;;     硬编码 --gtk-single-instance=false 且不可配置）——与本
;;;     app 的 open-any-terminal 各出一个"在 Ghostty 中打开"。
;;;     本 app 用 stub 遮蔽：nautilus-python 扫描顺序（loader
;;;     nautilus-python.c nautilus_python_check_all_directories）
;;;     是 ~/.local/share 最先，且按 basename 走 Python 模块名
;;;     缓存——仓库 stub 先导入，saayix 同名模块不再加载。
;;;     不采用 patch ghostty 包删除文件的方式：加 build phase
;;;     会改变 derivation，触发 VM 上整个 ghostty zig 重建
;;;     （saayix 无公共 substitute）。
;;;
;;; 无 persistence 规则（nautilus 状态属用户数据层）。

(define-module (guixcfg apps nautilus definition)
               #:use-module (gnu packages gnome) ; nautilus、gvfs
               #:use-module (gnu packages glib)  ; gobject-introspection（cairo-1.0.typelib）
               #:use-module (gnu packages python) ; python（site-packages 版本推导）
               #:use-module (gnu home services) ; home-environment-variables-service-type、home-files-service-type
               #:use-module (gnu services)     ; simple-service
               #:use-module (guix gexp)        ; local-file
               #:use-module (guix packages)    ; package-version
               #:use-module (virelith packages nautilus) ; python-nautilus、nautilus-open-any-terminal
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg gsettings model) ; gsettings-setting
               #:use-module (guixcfg users user) ; %primary-user、user-profile-home-directory
               #:use-module (srfi srfi-1)       ; take
               #:export (%nautilus))

;; loader 内嵌解释器的 site-packages 搜索路径：profile 下
;; lib/python<major.minor>/site-packages。版本号从 pinned python
;; 推导（与 python-nautilus 的编译期 input 同源——virelith
;; nautilus.scm 的 (gnu packages python) python），与 profile 里
;; pygobject/gi 的安装目录一致，不写死 "3.12"。
(define %nautilus-python-major-minor
  (string-join (take (string-split (package-version python) #\.) 2)
               "."))

(define %nautilus-python-path
  (string-append (user-profile-home-directory %primary-user)
                 "/.guix-home/profile/lib/python"
                 %nautilus-python-major-minor
                 "/site-packages"))

;; stub（遮蔽 saayix ghostty 的 bundled 扩展）：必须是一个可干净
;; 导入的 Python 模块——nautilus-python 先扫 ~/.local/share，按
;; basename 导入（模块名缓存），本 stub 先于 profile 里的
;; ghostty.py 成为模块 "ghostty"，saayix 那份不再加载。内容静态
;; → 独立文件 colocate（同目录 ghostty.py）。
(define %ghostty-nautilus-extension-stub
  (local-file "ghostty.py"))

(define %nautilus
  (application
   (name 'nautilus)
   ;; gvfs：trash 的 D-Bus activation 服务文件所在包（见上）。
   ;; python-nautilus + nautilus-open-any-terminal：右键"打开终端"扩展
   ;; （gtk/pygobject 经扩展的 propagated-inputs 随闭包进入 profile）。
   ;; gobject-introspection：cairo-1.0.typelib 的携带者——guix 的
   ;; cairo 不构建 introspection（无 typelib），而扩展经 gi 导入
   ;; Gtk 3.0 时其 typelib 依赖 namespace cairo；缺失时扩展 import
   ;; 静默失败、菜单不出现（2026-09 VM 实测 ImportError）。GI 的
   ;; typelib 搜索（XDG_DATA_DIRS/../lib/girepository-1.0）经
   ;; profile 合并即可命中。
   (home-packages (list nautilus gvfs
                        python-nautilus nautilus-open-any-terminal
                        gobject-introspection))
   ;; PYTHONPATH：loader 内嵌 python 发现 profile 里 gi 的唯一通道
   ;; （见文件头 2026-09 断点记录）；stub 遮蔽 ghostty bundled 扩展
   ;; 防重复菜单项（同记录）。
   (home-services
    (list (simple-service
           'nautilus-python-env
           home-environment-variables-service-type
           (list (cons "PYTHONPATH" %nautilus-python-path)))
          (simple-service
           'nautilus-suppress-ghostty-extension
           home-files-service-type
           `((".local/share/nautilus-python/extensions/ghostty.py"
              ,%ghostty-nautilus-extension-stub)))))
   ;; 扩展的终端选择：ghostty（本仓库唯一 terminal）。
   (gsettings
    (list (gsettings-setting
           (schema "com.github.stunkymonkey.nautilus-open-any-terminal")
           (key "terminal")
           (value "'ghostty'"))))))
