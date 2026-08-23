;;; Noctalia（noctalia-git channel 包）。
;;;
;;; 配置模型（seed-once，docs/architecture/persistence.md
;;; （seed-once）；本任务决策记录）：
;;;   Guix 只提供初始配置 seed（base-settings.toml → 首次 activation
;;;   写入 backing 侧的 settings.toml——canonical backing，persistence
;;;   root 相对路径见 rule 声明），此后 ~/.local/state/noctalia/**
;;;   完全由 Noctalia/用户运行时管理——整目录经 application
;;;   persistence bind 持久化（settings.toml、state.toml、
;;;   .setup-complete 及未来任何新 state 文件，无白名单）。
;;;
;;; 明确不做：Guix 长期声明式管理 ~/.config/noctalia/config.toml
;;; （双配置源——settings 唯一来源是 seed + app 自管）；不持久化
;;; ~/.cache/noctalia、~/.local/share/noctalia（独立 XDG 数据类别，
;;; 另行评估）。唯一例外：
;;; ~/.config/noctalia/palettes/ 是**静态素材**（custom palette，
;;; 非 settings 配置；pinned Noctalia src/theme/custom_palettes.cpp
;;; 读取 configDir()/palettes/*.json）——repo-owned 声明式安装，
;;; 与 app 保存生成的调色板（同名文件除外）按路径分权共存
;;; （mixed-authority，docs/architecture/persistence.md）。注意：
;;; 该目录是 ephemeral HOME，app 保存的生成调色板不跨 boot 保留
;;; （如需持久化另行评估，不做文件白名单式绑定）。
;;;
;;; niri 集成：~/.config/niri/noctalia.kdl 由 Noctalia 运行时生成
;;; （唯一 owner = Noctalia），与 seed 模型无关（见 apps/niri）。
;;;
;;; GTK 动态配色（任务七边界）：templates/gtk{3,4}.css 是 pinned
;;; Noctalia 内置模板的 vendored 副本（stock post-hook apply.sh 含
;;; gtk.css mutation——store symlink 缺 import 时会 rm 重建——不用）；
;;; 经 xdg-config 发布为 ~/.config/noctalia/templates/，由 seed 的
;;; [theme.templates.user.gtk{3,4}] 引用，只生成
;;; gtk-{3,4}/noctalia.css；post-hook 是窄职责的 appearance-sync
;;; （apps/gtk）。内置 gtk3/gtk4 template 在 seed 的 builtin_ids 中
;;; 已移除（双 hook owner 禁令同 §7）。

(define-module (guixcfg apps noctalia-git definition)
               #:use-module (noctalia)                 ; noctalia-git
               #:use-module (gnu home services)        ; home-xdg-configuration-files-service-type
               #:use-module (gnu services)             ; simple-service
               #:use-module (guix gexp)                ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)       ; application
               #:use-module (guixcfg system application-persistence) ; application-persistence-rule
               #:export (%noctalia-git))

(define %noctalia-git
  (application
   (name 'noctalia-git)
   (home-packages (list noctalia-git))                 ; 用户 profile 包（service 自动贡献的不要重复）
   (home-services
    (list (simple-service 'noctalia-palettes
                          home-xdg-configuration-files-service-type
                          `(("noctalia/palettes/fluent-blue.json"
                             ,(local-file "fluent-blue.json"
                                          "noctalia-fluent-blue.json"))))
          ;; GTK 动态配色模板（vendored；user template 的
          ;; input_path——见头部 GTK 段）。
          (simple-service 'noctalia-gtk-templates
                          home-xdg-configuration-files-service-type
                          `(("noctalia/templates/gtk3.css"
                             ,(local-file "templates/gtk3.css"
                                          "noctalia-gtk3.css"))
                            ("noctalia/templates/gtk4.css"
                             ,(local-file "templates/gtk4.css"
                                          "noctalia-gtk4.css"))))))
   (persistence
    (list (application-persistence-rule
           (name 'state)
           (backing "noctalia/state")          ; persistence root 下相对路径
           (consumer ".local/state/noctalia") ; 整个 XDG_STATE_HOME/noctalia（app-private）
           (exposure 'bind-directory)
           (lifecycle 'application-owned)
           ;; seed-once：首次初始化 settings.toml；此后 repo 永不触碰。
           (seeds `(("settings.toml"
                     ,(local-file "base-settings.toml" "noctalia-base-settings.toml")))))))))
