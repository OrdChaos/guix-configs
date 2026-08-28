;;; nushell application unit：Nushell（自建 virelith channel 提供的
;;; 官方 glibc release 二进制包）。
;;;
;;; 来源（pinned virelith bd217238 审计）：nushell 定义于
;;; (virelith packages nushell)，v0.115.1，nonguix binary-build-
;;; system（upstream glibc tarball，patchelf interpreter/RUNPATH 指
;;; 向 Guix glibc/zlib/libgcc_s）；安装 nu + 8 个 nu_plugin_* 到
;;; $out/bin。插件【注册】由本模块构建期声明式完成（nushell-plugin-
;;; registry，见下）——包只安装 executable，注册是配置层职责。
;;;
;;; 路径实测（virelith nushell 0.115.1，scratch HOME 实测）：
;;;   $nu.config-path   ~/.config/nushell/config.nu
;;;   $nu.env-path      ~/.config/nushell/env.nu
;;;   $nu.history-path  默认 ~/.config/nushell/history.txt ——但
;;;     0.115.1 的 $env.config.history.path 支持自定义路径
;;;     （HistoryPath::Custom，pinned 源码 crates/nu-protocol/src/
;;;     config/history.rs 审计：非空字符串 → Custom(PathBuf)，空串
;;;     → Default，null → Disabled；~ 不展开，需运行时表达式）；
;;;   $nu.plugin-path   ~/.config/nushell/plugin.msgpackz
;;;   $nu.data-dir      ~/.local/share/nushell
;;;   $nu.cache-dir     ~/.cache/nushell
;;;
;;; 配置/持久化边界（2026-08-25 决策；plugin registry 2026-08-26
;;; 改为构建期声明式生成）：
;;;   仓库分发（声明式，home-files，.config 前缀）：
;;;     ~/.config/nushell/config.nu      —— history 重定向到
;;;       ~/.local/state/nushell/history.txt（$env.HOME 运行时拼接，
;;;       不硬编码用户名），使 ~/.config/nushell/ 保持纯声明式；
;;;     ~/.config/nushell/env.nu         —— 注释占位（确立 ownership，
;;;       防首启生成第二权威）；无环境覆盖偏好；
;;;     ~/.config/nushell/plugin.msgpackz —— 构建期生成的 registry
;;;       （nushell-plugin-registry：computed-file，Guix build graph
;;;       内当前 nu + 声明的插件 executable 生成；store-backed）。
;;;   （login.nu / autoload/ / scripts/ 暂不创建——无实际需要；
;;;    不为了目录完整性造空文件）
;;;   持久化（application persistence，bind-directory）：
;;;     ~/.local/state/nushell/  →  backing root 相对（persistence.md）
;;;       （history.txt 所在目录；与 mpv 的 .local/state/mpv 同模式）
;;;   不持久化（可重建/派生）：
;;;     cache（$nu.cache-dir = ~/.cache/nushell）
;;;     data-dir（$nu.data-dir = ~/.local/share/nushell——当前无
;;;       真实用户数据；将来出现再按内容评估，不整体持久化）
;;;
;;; 明确不做：修改个人 channel 的 package；切官方 guix nushell；
;;; 设默认 login shell；在 config.nu 中 plugin add/use；为 plugin
;;; registry 建 persistence rule（store-backed 声明式配置，重建随
;;; generation 自动恢复）；NU_PLUGIN_DIRS（registry 内是绝对 store
;;; 路径，无需搜索路径）。

(define-module (guixcfg apps nushell definition)
               #:use-module (gnu home services)      ; home-files-service-type
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; local-file、file-append、computed-file
               #:use-module (guix records)
               #:use-module (virelith packages nushell) ; nushell（自建 channel）
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%nushell
                         %nushell-default-plugins
                         nushell-plugin-registry))

;; 默认注册的官方插件集合（Nushell 官方 default non-developer
;; plugins；custom_values/example/stress_internals 属 example/
;; developer/internal testing 类，不注册——仍由 package 安装到
;; $out/bin，只是不进声明式 registry）。未来第三方插件可在此追加
;; 独立 package 的 executable（file-append 模型，不限同 package）。
(define %nushell-default-plugins
  '("nu_plugin_inc"
    "nu_plugin_polars"
    "nu_plugin_gstat"
    "nu_plugin_formats"
    "nu_plugin_query"))

(define (nushell-plugin-registry)
  "构建期生成 plugin.msgpackz（computed-file，Guix build graph 内）：
当前 generation 的 nu --plugin-config <out> --commands 'plugin add
<绝对 store 路径>; ...'。插件 executable 经 file-append 引用 nushell
package——registry derivation 显式依赖具体插件 store 路径；nu/插件
升级 → derivation input 变化 → registry 自动重新生成（满足 Nushell
官方'插件升级后重新 plugin add'要求，无需自实现版本检测）。

实测语义（virelith nushell 0.115.1）：
  - registry 文件不存在时 plugin add 自动创建（无需预建空文件）；
  - nu --commands/-c 不加载用户 config.nu/env.nu——构建完全不依赖
    用户配置；sandbox 无 HOME/XDG 也可运行（env -i 实测）；
  - plugin add 只写 registry，不做 plugin use（同一解析阶段不自动
    成立 use——按上游语义不声明 use）。
只读声明式语义：分发后 ~/.config/nushell/plugin.msgpackz 是 store-
backed 链接；用户直接 plugin add 修改默认 $nu.plugin-path 会因只读
失败——预期行为（永久插件 → 改仓库声明 → reconfigure 重新生成）。
不持久化 registry；不做 activation/login 生成。"
  (let ((nu (file-append nushell "/bin/nu"))
        (plugins (map (lambda (plugin)
                        (file-append nushell "/bin/" plugin))
                      %nushell-default-plugins)))
    (computed-file
     "nushell-plugin-registry.msgpackz"
     #~(begin
        (define nu #$nu)
        ;; gexp 运行时（构建期）拼接命令串：全部 Guile core
        ;; binding（AGENT.md §3），无额外 import。
        (define commands
          (apply string-append
            (map (lambda (plugin)
                   (string-append "plugin add " plugin "; "))
                 (list #$@plugins))))
        (unless (zero?
                 (system* nu
                          (string-append "--plugin-config=" #$output)
                          "--commands"
                          commands))
          (error "nushell plugin registry generation failed"))))))

(define %nushell
  (application
   (name 'nushell)
   (home-packages (list nushell))
   (home-services
    (list (simple-service 'nushell-config
                          home-files-service-type
                          `((".config/nushell/config.nu"
                             ,(local-file "config.nu" "nushell-config.nu"))
                            (".config/nushell/env.nu"
                             ,(local-file "env.nu" "nushell-env.nu"))
                            (".config/nushell/theme.nu"
                             ,(local-file "theme.nu" "nushell-theme.nu"))
                            (".config/nushell/plugin.msgpackz"
                             ,(nushell-plugin-registry))))))
   (persistence
    (list (application-persistence-rule
           (name 'state)
           (backing "nushell/state")        ; backing root 相对（persistence.md）
           (consumer ".local/state/nushell") ; HOME 相对（history 所在目录；
           ;   XDG_STATE_HOME 语义，mpv 同模式）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
