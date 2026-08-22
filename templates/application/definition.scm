;;; Application definition 模板（新应用的正式入口）。
;;;
;;; 标准流程（docs/development/applications.md 教程 E1-E10；架构见
;;; docs/architecture/applications.md）：
;;;   cp -r templates/application modules/guixcfg/apps/foo
;;;   1. 修改模块名 (guixcfg apps foo definition)；
;;;   2. 修改 %APP → %foo 与 (name 'app) → (name 'foo)；
;;;   3. 公开配置直接放进 apps/foo/（如 config.kdl；可选配置变体放
;;;      apps/foo/variants/）；
;;;   4. 单一 owner 的加密密文放 apps/foo/secrets/*.age（多消费者/
;;;      system/host/install 域仍走 top-level secrets/ +
;;;      (guixcfg utils repository-source)）；
;;;   5. 填 definition.scm（只声明 contributions）；
;;;   6. 在 apps/registry.scm 显式 import + 加入 %applications；
;;;   7. build/test/reconfigure。
;;;
;;; 规则（AGENT.md §Application layer）：
;;;   - definition 只声明 contributions；部署/挂载/发布由各自的
;;;     generic single-owner mechanism 执行（Guix Home、file-systems、
;;;     secrets publisher、selection resolver）；
;;;   - app-local static source 用 source-relative local-file
;;;     （(local-file "config.kdl") 按本文件所在目录解析）；
;;;   - 官方 Home service 自动贡献的 package 不要重复声明；
;;;   - mutable app state 走 persistence rules
;;;     （<application-persistence-rule>，bind-only，不持久化整个
;;;     .config/.local/.cache）；
;;;   - 可选配置变体（configuration-variants）：application 声明
;;;     资源与 logical variant（<application-configuration-variant>，
;;;     name + files）；host 只做 selection（(guixcfg apps selection)），
;;;     不知道文件/路径（见 docs/development/applications.md E9）；
;;;   - 目录存在 != 应用启用：启用必须进 registry。

(define-module (guixcfg apps app definition)
               #:use-module (gnu services)             ; service
               #:use-module (guix gexp)                ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)       ; application
               #:export (%app))

(define %app
  (application
   (name 'app)                       ; symbol：registry 里唯一
   ;; (home-packages (list ...))     ; 用户 profile 包（service 自动贡献的不要重复）
   ;; (home-services (list ...))     ; home service 实例（官方 home-*-service-type）
   ;; (system-services (list ...))   ; system service（仅确有必要；greetd/elogind/
   ;;                                 ; accounts/SSH host keys/readiness/TPM/UKI/
   ;;                                 ; Secure Boot 等 core infrastructure 不迁进 apps）
   ;; (persistence (list ...))       ; <application-persistence-rule>（bind-only）
   ;; (secrets (list ...))           ; <secret-decl>（source = 本目录 secrets/ 的
   ;;                                 ; file-like，如 (local-file "secrets/x.age")）
   ;; (configuration-variants        ; 可选配置变体（application-owned）：
   ;;  (list (application-configuration-variant
   ;;         (name 'laptop)          ; logical identifier（host selection 用）
   ;;         (files `(("foo/device.conf"    ; 完整 ~/.config 相对 target
   ;;                   ,(local-file "variants/laptop.conf")))))))
   ))
