;;; vscode application unit：Microsoft Visual Studio Code（自建
;;; virelith channel 提供的官方 Linux x64 二进制包）。
;;;
;;; 来源（pinned virelith d233d134 审计）：vscode 定义于
;;; (virelith packages vscode)，v1.134.0，chromium-binary-build-
;;; system（nonguix 提供：注入 Electron runtime input 集、按
;;; wrapper-plan 做 patchelf、包入口包装）。包层自带：
;;;   - /bin/code（symlink → opt/vscode/VSCode-linux-x64/code，
;;;     install-entrypoint 阶段）；
;;;   - share/applications/vscode.desktop（install-resources 阶段
;;;     make-desktop-entry-file，Exec 含 --ozone-platform-hint=auto
;;;     ——Wayland 提示是包层职责，配置层不重写 desktop entry）；
;;;   - share/icons/hicolor/512x512/apps/code.png。
;;; 不复制定义、不自建 wrapper、不处理 chrome-sandbox/patchelf/
;;; LD_LIBRARY_PATH/FHS（AGENT.md §7 Officialization——全部属
;;; channel/package 层职责）。
;;;
;;; 配置与持久化边界（2026-08-25 决策，三层）：
;;;   仓库管理（repo-owned，home-xdg-configuration-files 单向声明式；
;;;   不持久化、不做启动复制/退出回写、VS Code 运行时改写失败属
;;;   预期——声明式边界）：
;;;     ~/.config/Code/User/settings.json      —— 最小集合（见下）；
;;;     ~/.config/Code/User/keybindings.json   —— 空声明（当前无自定义
;;;       键位；占位确立 ownership，防运行时生成第二权威）；
;;;     ~/.config/Code/User/snippets/          —— 暂不创建（无 snippet）；
;;;     ~/.config/Code/User/tasks.json         —— 暂不创建（无用户级任务）；
;;;     ~/.vscode/argv.json                   —— VS Code runtime args
;;;       （home-files：~/.vscode 不在 XDG .config 下）。只声明
;;;       "enable-crash-reporter": false——pinned 1.134.0 main.js 的
;;;       updateCrashReporterEnablement 审计：argv.json 缺该键时 VS
;;;       Code 会在启动时【重写整个文件】（注释 + 键），对只读 store
;;;       symlink 会失败——显式声明后跳过重写路径；该键是 VS Code
;;;       官方唯一自行管理的 argv 键（其注释 "Allows to disable crash
;;;       reporting"），关闭崩溃上报与 update.mode=none 的无后台
;;;       上报姿态一致。不添加 --no-sandbox / GPU 等未经验证的
;;;       Electron flag（未来 Wayland/IME 参数走 desktop entry/
;;;       launcher 层，argv.json 只支持部分 Electron switches）。
;;;   settings.json 内容（pinned vscode 1.134.0 构建产物核实——
;;;   out/vs/workbench 的 configuration 注册）：
;;;     "extensions.autoUpdate": false  —— 已审计 extension 不被后台
;;;        自行升级（改变运行边界）；
;;;     "update.mode": "none"           —— VS Code 二进制由 Guix
;;;        channel 更新，不由 VS Code 自更新（enum 含 none，核实）。
;;;   持久化（application persistence，bind-directory）：
;;;     ~/.vscode/extensions/                         —— 官方 extension
;;;        安装目录（marketplace/手动安装，非仓库声明式）；
;;;     ~/.config/Code/User/globalStorage/            —— 全局用户/
;;;        extension 状态（state.vscdb 等，非 cache）；
;;;     ~/.config/Code/User/workspaceStorage/         —— 按 workspace
;;;        隔离的状态；
;;;     ~/.config/Code/User/History/                  —— Local History
;;;        （误删/误改恢复数据；重要用户数据）。
;;;     不持久化 profiles/（当前不采用 Profiles——profile-scoped
;;;     配置会造成第二套 ownership；VS Code 自行产生的 metadata 不
;;;     扩大任务，仅记录）。
;;;   临时/可丢弃（随 ephemeral HOME 消失，不持久化）：
;;;     ~/.config/Code/logs/、CachedData/、
;;;     CachedExtensionVSIXs/、Cache*/、GPUCache/、Dawn*/、
;;;     ~/.cache/Code/ 等可重建的 cache/runtime 数据。
;;;
;;; 声明式扩展（2026-08-26）：固定插件集合 %vscode-declared-extensions
;;; 经构建期 vsix 解包（computed-file）+ home activation 幂等部署到
;;; ~/.vscode/extensions/（持久化 bind 目标）：
;;;   - 部署语义："部署即存在，不存在则加上，存在则不变"——activation
;;;     按插件目录名 file-exists? 跳过（用户已有版本不被覆盖）；
;;;   - 其他插件不触碰（不删不动）；
;;;   - vsix 是 fixed-output origin（版本 + sha256 固定，构建期下载）；
;;;     插件升级 = 改声明 → reconfigure → 新 generation 重新部署。
;;;
;;; 职责边界（docs/architecture/applications.md）：
;;;   - 本模块只声明"vscode 是什么"：package 安装 + desktop entry
;;;     纯数据常量 + 声明式配置文件 + persistence rules + 固定扩展；
;;;   - MIME/default editor、language servers、argv.json 等均未配置
;;;     （后续单独设计）；
;;;   - sandbox：包默认 Electron/Chromium 正常 user namespace
;;;     sandbox，配置层不加 --no-sandbox、不做 setuid
;;;     chrome-sandbox workaround（未来真实运行证明内核/userns
;;;     不兼容时才作为 host/config 层显式 opt-in）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 提示由包层
;;; Exec 参数提供；portal 由 niri 会话提供。

(define-module (guixcfg apps vscode definition)
               #:use-module (gnu home services)      ; home-xdg-configuration-files-service-type、home-activation-service-type
               #:use-module (gnu packages compression) ; unzip（vsix 解包）
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix download)          ; url-fetch
               #:use-module (guix gexp)              ; local-file、computed-file、file-append
               #:use-module (guix packages)          ; origin
               #:use-module (guix records)
               #:use-module (virelith packages vscode) ; vscode（自建 channel）
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%vscode-extension-vsixs
                         %vscode
                         %vscode-desktop-entry
                         %vscode-declared-extensions
                         vscode-extensions-directory))

;; 声明的固定插件集合（2026-08-26 固定；版本/URL/sha256 均为
;; 下载时实测）：(插件目录名 vsix-url sha256-base32)。
;;   - MS-CEINTL.vscode-language-pack-zh-hans 1.131.0（Open VSX）
;;   - huytd.nord-light 0.1.1（Marketplace gallerycdn 稳定 URL——
;;     vsassets.io 历史版本永久可下载，同 vscode 包下载模型）
(define %vscode-declared-extensions
  '(("MS-CEINTL.vscode-language-pack-zh-hans-1.131.0"
     "https://openvsx.org/api/MS-CEINTL/vscode-language-pack-zh-hans/1.131.0/file/MS-CEINTL.vscode-language-pack-zh-hans-1.131.0.vsix"
     "158q9nz2jy95837k9pdf2d88ah2zrbbc2lk7slp9958gk2z9vz3z")
    ("huytd.nord-light-0.1.1"
     "https://huytd.gallerycdn.vsassets.io/extensions/huytd/nord-light/0.1.1/1643088410652/Microsoft.VisualStudio.Services.VSIXPackage"
     "13zvk5l5d4n8vjkn36r62n98n0nbcpxfz2ad2z325p337vg8cqdb")))

;;; 声明的 vsix fixed-output origins（Scheme 层构造，gexp 内引用
;;; 自动成为 derivation 依赖）。
(define %vscode-extension-vsixs
  (map (lambda (spec)
         (origin
           (method url-fetch)
           (uri (cadr spec))
           (sha256 (base32 (caddr spec)))))
       %vscode-declared-extensions))

(define (vscode-extensions-directory)
  "构建期把声明的 vsix 解包成插件目录树（每个插件一个子目录，
vsix 的 extension/ 内容即插件目录内容；输出 store 目录）。"
  (computed-file
   "vscode-declared-extensions"
   #~(begin
       (use-modules (guix build utils))
       (define unzip #$(file-append unzip "/bin/unzip"))
       (for-each
        (lambda (name vsix)
          (invoke unzip "-q" vsix "-d" name)
          (copy-recursively (string-append name "/extension")
                            (string-append #$output "/" name))
          (delete-file-recursively name))
        (list #$@(map car %vscode-declared-extensions))
        (list #$@%vscode-extension-vsixs)))
   #:options '(#:modules ((guix build utils)))))

;; VS Code 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %vscode-desktop-entry "vscode.desktop")

(define %vscode
  (application
   (name 'vscode)
   (home-packages (list vscode))
   (home-services
    (list (simple-service 'vscode-user-config
                          home-xdg-configuration-files-service-type
                          `(("Code/User/settings.json"
                             ,(local-file "settings.json" "vscode-settings.json"))
                            ("Code/User/keybindings.json"
                             ,(local-file "keybindings.json"
                                          "vscode-keybindings.json"))))
          ;; ~/.vscode/argv.json 不在 XDG .config 下——走 home-files
          ;; （.config 外 HOME dotfile 的既有通道；apps/model 校验
          ;; 只拒绝 .config 目标）。
          (simple-service 'vscode-argv-json
                          home-files-service-type
                          `((".vscode/argv.json"
                             ,(local-file "argv.json" "vscode-argv.json"))))
          ;; 声明式扩展部署（幂等）：~/.vscode/extensions/ 是持久化
          ;; bind 目标（boot 时已挂载）；activation 以用户身份运行，
          ;; 按插件目录名 file-exists? 跳过（"不存在则加上，存在则
          ;; 不变"）；其他插件不触碰。computed-file 在构建期把 vsix
          ;; 解包成插件目录树。
          (simple-service 'vscode-extensions-deploy
                          home-activation-service-type
                          #~(begin
                              (use-modules (guix build utils))
                              (let ((extensions-dir
                                     (string-append
                                      (getenv "HOME")
                                      "/.vscode/extensions")))
                                (mkdir-p extensions-dir)
                                (for-each
                                 (lambda (name)
                                   (let ((target
                                          (string-append
                                           extensions-dir "/" name)))
                                     (unless (file-exists? target)
                                       (copy-recursively
                                        (string-append
                                         #$(vscode-extensions-directory)
                                         "/" name)
                                        target))))
                                 (list #$@(map car
                                               %vscode-declared-extensions))))))))
   (persistence
    (list (application-persistence-rule
           (name 'extensions)
           (backing "vscode/extensions")     ; backing root 相对（persistence.md）
           (consumer ".vscode/extensions")   ; HOME 相对（官方 extension 目录）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'global-storage)
           (backing "vscode/global-storage")
           (consumer ".config/Code/User/globalStorage")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'workspace-storage)
           (backing "vscode/workspace-storage")
           (consumer ".config/Code/User/workspaceStorage")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'local-history)
           (backing "vscode/local-history")
           (consumer ".config/Code/User/History")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
