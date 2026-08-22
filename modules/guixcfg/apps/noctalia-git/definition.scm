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
                                          "noctalia-fluent-blue.json"))))))
   ;; (system-services (list ...))   ; system service（仅确有必要；greetd/elogind/
   ;;                                 ; accounts/SSH host keys/readiness/TPM/UKI/
   ;;                                 ; Secure Boot 等 core infrastructure 不迁进 apps）
   (persistence
    (list (application-persistence-rule
           (name 'state)
           (backing "noctalia/state")          ; persistence root 下相对路径
           (consumer ".local/state/noctalia") ; 整个 XDG_STATE_HOME/noctalia（app-private）
           (exposure 'bind-directory)
           (lifecycle 'application-owned)
           ;; seed-once：首次初始化 settings.toml；此后 repo 永不触碰。
           (seeds `(("settings.toml"
                     ,(local-file "base-settings.toml" "noctalia-base-settings.toml")))))))
   ;; (secrets (list ...))           ; <secret-decl>（source = 本目录 secrets/ 的
   ;;                                 ; file-like，如 (local-file "secrets/x.age")）
   ))
