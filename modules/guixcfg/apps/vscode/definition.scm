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
;;; 配置与持久化边界（2026-08-31 决策，四类）：
;;;   仓库管理（repo-owned，home-files 单向声明式，.config 前缀；
;;;   不持久化、不做启动复制/退出回写、VS Code 运行时改写失败属
;;;   预期——声明式边界）：
;;;     ~/.config/Code/User/settings.json      —— 最小集合（见下）；
;;;     ~/.config/Code/User/keybindings.json   —— 空声明（当前无自定义
;;;       键位；占位确立 ownership，防运行时生成第二权威）；
;;;     ~/.config/Code/User/snippets/          —— 暂不创建（无 snippet）；
;;;     ~/.config/Code/User/tasks.json         —— 暂不创建（无用户级任务）；
;;;     ~/.vscode/argv.json                   —— VS Code runtime args
;;;       （home-files：~/.vscode 不在 XDG .config 下）。三个字段：
;;;       enable-crash-reporter = false
;;;         禁止 crash reporter；同时避免 VS Code 因缺少该键尝试
;;;         改写 repo-owned argv.json（pinned 1.134.0 main.js 的
;;;         updateCrashReporterEnablement 审计：argv.json 缺该键时
;;;         VS Code 会在启动时【重写整个文件】（注释 + 键），对只读
;;;         store symlink 会失败——显式声明后跳过重写路径；该键是
;;;         VS Code 官方唯一自行管理的 argv 键，关闭崩溃上报与
;;;         update.mode=none 的无后台上报姿态一致）；
;;;       password-store = gnome-libsecret
;;;         使用 Secret Service / gnome-libsecret；
;;;       locale = zh-cn
;;;         请求简体中文 UI；但实际语言包解析仍依赖
;;;         application-owned ~/.config/Code/languagepacks.json
;;;         （见下）——locale 只是请求，语言包 metadata 缺失时 UI
;;;         仍回退英语。
;;;       不添加 --no-sandbox / GPU 等未经验证的 Electron flag
;;;       （未来 Wayland/IME 参数走 desktop entry/launcher 层，
;;;       argv.json 只支持部分 Electron switches）。
;;;   settings.json 内容（pinned vscode 1.134.0 构建产物核实——
;;;   out/vs/workbench 的 configuration 注册）：
;;;     "extensions.autoUpdate": false  —— 已审计 extension 不被后台
;;;        自行升级（改变运行边界）；
;;;     "update.mode": "none"           —— VS Code 二进制由 Guix
;;;        channel 更新，不由 VS Code 自更新（enum 含 none，核实）。
;;;   应用自有持久化（application-owned persistent，application
;;;   persistence；canonical backing 是 data-app root 下的
;;;   vscode/...，consumer 是 HOME 相对 bind projection）：
;;;     ~/.vscode/extensions/                         —— 官方 extension
;;;        安装目录（marketplace/手动安装，非仓库声明式）；
;;;     ~/.config/Code/languagepacks.json             —— bind-file
;;;        （单文件）。installed language-pack metadata：VS Code 在
;;;        很早的 NLS 初始化阶段（main 进程先于窗口的
;;;        createNlsConfiguration）直接读它解析 locale 语言包；
;;;        仅保留 ~/.vscode/extensions/ 不足以恢复非英语 UI
;;;        （语言包 extension 存在但 metadata 文件缺失 → UI 回退
;;;        英语——pinned 1.134.0 main.js 审计）。它是 VS Code 自己
;;;        维护的 mutable application state，因此不能由仓库生成。
;;;        其更新模型是直接写同一路径（fs writeFile 直写，非
;;;        temp-file+rename 原子替换——pinned 1.134.0
;;;        cliProcessMain.js languagePacksService 审计），单文件
;;;        bind mount 合适（generic (exposure 'bind-file)，非
;;;        VS Code 特例）；
;;;     ~/.config/Code/clp/                           —— NLS compiled
;;;        cache（bind-directory）。derived cache、可重建：缓存目录
;;;        按 language-pack hash + locale + VS Code commit 版本隔离
;;;        （clp/<hash>.<locale>/<commit>/nls.messages.json），
;;;        stale 条目自然失效，corrupted.info marker 触发自愈重建
;;;        （pinned 1.134.0 main.js 审计）。持久化只为消除 ephemeral
;;;        HOME 重建后首次启动的 cold-start regeneration——不是
;;;        不可丢失用户数据；
;;;     ~/.config/Code/User/globalStorage/            —— 全局用户/
;;;        extension 状态（state.vscdb 等，非 cache）；
;;;     ~/.config/Code/User/workspaceStorage/         —— 按 workspace
;;;        隔离的状态；
;;;     ~/.config/Code/User/History/                  —— Local History
;;;        （误删/误改恢复数据；重要用户数据）。
;;;     不持久化 profiles/（当前不采用 Profiles——profile-scoped
;;;     配置会造成第二套 ownership；VS Code 自行产生的 metadata 不
;;;     扩大任务，仅记录）。
;;;   临时/可丢弃（ephemeral，随 ephemeral HOME 消失，不持久化）：
;;;     ~/.config/Code/logs/、CachedData/、
;;;     CachedExtensionVSIXs/、Cache*/、GPUCache/、Dawn*/、
;;;     ~/.cache/Code/ 等可重建的 cache/runtime 数据。
;;;
;;; 职责边界（docs/architecture/applications.md）：
;;;   - 本模块只声明"vscode 是什么"：package 安装 + desktop entry
;;;     纯数据常量 + 声明式配置文件 + persistence rules；
;;;   - argv.json 的稳定 early-startup/runtime 参数由本模块声明式
;;;     管理；MIME/default editor、language servers、固定 extension
;;;     集合等仍由其他模块决定；
;;;   - sandbox：包默认 Electron/Chromium 正常 user namespace
;;;     sandbox，配置层不加 --no-sandbox、不做 setuid
;;;     chrome-sandbox workaround（未来真实运行证明内核/userns
;;;     不兼容时才作为 host/config 层显式 opt-in）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 提示由包层
;;; Exec 参数提供；portal 由 niri 会话提供。

(define-module (guixcfg apps vscode definition)
               #:use-module (gnu home services)      ; home-files-service-type
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix records)
               #:use-module (virelith packages vscode) ; vscode（自建 channel）
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%vscode
                         %vscode-desktop-entry))

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
                          home-files-service-type
                          `((".config/Code/User/settings.json"
                             ,(local-file "settings.json" "vscode-settings.json"))
                            (".config/Code/User/keybindings.json"
                             ,(local-file "keybindings.json"
                                          "vscode-keybindings.json"))))
          ;; ~/.vscode/argv.json 不在 XDG .config 下——同样走
          ;; home-files（HOME dotfile 通道）。
          (simple-service 'vscode-argv-json
                          home-files-service-type
                          `((".vscode/argv.json"
                             ,(local-file "argv.json" "vscode-argv.json"))))))
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
           (lifecycle 'application-owned))
          ;; installed language-pack metadata：VS Code 早期 NLS 初始化
          ;; 直接读它解析 locale；app 自己维护 + 直写同一路径（非
          ;; temp+rename）→ 单文件 bind（file→file）。
          (application-persistence-rule
           (name 'language-packs)
           (backing "vscode/languagepacks.json")
           (consumer ".config/Code/languagepacks.json")
           (exposure 'bind-file)
           (lifecycle 'application-owned))
          ;; NLS compiled cache：derived/rebuildable（clp/<hash>.
          ;; <locale>/<commit>/；corrupted.info 自愈重建）。持久化
          ;; 只为消除 cold-start regeneration，非不可丢失用户数据。
          (application-persistence-rule
           (name 'language-pack-cache)
           (backing "vscode/clp")
           (consumer ".config/Code/clp")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
