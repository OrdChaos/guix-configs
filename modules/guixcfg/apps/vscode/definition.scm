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
;;; 职责边界（docs/architecture/applications.md）：
;;;   - 本模块只声明"vscode 是什么"：package 安装 + desktop entry
;;;     纯数据常量（%vscode-desktop-entry，供未来统一 XDG 策略
;;;     模块消费；当前不设 MIME/default editor——明确推迟）；
;;;   - 无 persistence rule（当前任务范围）：extensions
;;;     （~/.vscode/extensions）、globalStorage/workspaceStorage/
;;;     Local History（~/.config/Code/User/...）与 cache 边界的
;;;     审计与持久化单独设计（vscode persistence 边界文档
;;;     VS Code 配置与持久化边界 §5-§11）；
;;;   - settings.json / keybindings.json / snippets / argv.json /
;;;     Profiles 均未声明（后续单独处理）；
;;;   - sandbox：包默认 Electron/Chromium 正常 user namespace
;;;     sandbox，配置层不加 --no-sandbox、不做 setuid
;;;     chrome-sandbox workaround（未来真实运行证明内核/userns
;;;     不兼容时才作为 host/config 层显式 opt-in）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 提示由包层
;;; Exec 参数提供；portal 由 niri 会话提供。

(define-module (guixcfg apps vscode definition)
               #:use-module (guix records)
               #:use-module (virelith packages vscode) ; vscode（自建 channel）
               #:use-module (guixcfg apps model)
               #:export (%vscode
                         %vscode-desktop-entry))

;; VS Code 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %vscode-desktop-entry "vscode.desktop")

(define %vscode
  (application
   (name 'vscode)
   (home-packages (list vscode))))
