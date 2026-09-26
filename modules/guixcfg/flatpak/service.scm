;;; Flatpak 平台 Home/System 集成（docs/architecture/flatpak.md）。
;;;
;;; 本模块只做【离线生成式】投影——不 import (guixcfg flatpak
;;; reconcile)、不产生任何 flatpak CLI 调用（composition 测试静态
;;; 断言；网络边界不变量）：
;;;   - session env：XDG_DATA_DIRS 追加 per-user exports 目录
;;;     （home-environment-variables-service-type 共享 sink 的
;;;     native extension；追加不覆盖——pinned setup-environment 的
;;;     preamble 先置 Home profile share，本值经 shell-double-quote
;;;     发射（$ 保留）在 source 时展开 $XDG_DATA_DIRS）；
;;;   - override 完整文件：installation-wide font projection 写入 global；
;;;     definition 的 override-policy 为
;;;     (managed-overrides ...) 的 app 在 system activation 写入 Flatpak
;;;     installation backing 的 overrides/<id>（complete-file ownership，
;;;     repo 与 Flatseal 永不 merge）；'external → 不生成（user/Flatseal owns）。
;;;     不能由 Home 写入：installation 是持久化 bind，ephemeral HOME 会丢失
;;;     ~/.guix-home 的上代索引，导致 pinned symlink-manager 重复备份旧链接；
;;;   - desktop shadow：selected definition 的 desktop-files 投影到
;;;     ~/.local/share/applications/，经 XDG precedence 覆盖 Flatpak
;;;     export；完整文件 single-owner，不做字段级 merge；
;;;   - persistence rules：installation（平台拥有）+ 每个
;;;     **selected** app 的 persistence intent（默认
;;;     ~/.var/app/<id> 从 application ID 推导 + definition 的
;;;     extra-persistence 例外）——未选中的 app 不产生 mount。
;;;     全部经 (guixcfg system application-persistence) generic
;;;     engine 执行（host 组装点调用 flatpak-persistence-rules），
;;;     零 Flatpak 专属 mount 代码；installation 与 apps/<id> 为
;;;     平级 backing（regression 测试固定 parent/child 嵌套禁止）。

(define-module (guixcfg flatpak service)
               #:use-module (gnu home services) ; home-environment-variables-service-type、home-files-service-type
                #:use-module (gnu services)      ; simple-service、activation-service-type
                #:use-module (guix gexp)         ; plain-file、file-append、mixed-text-file
                #:use-module (guix modules)      ; source-module-closure
                #:use-module (guix packages)     ; package-name
                #:use-module (gnu packages fontutils) ; fontconfig
                #:use-module (srfi srfi-1)       ; filter-map、append-map
                #:use-module (sxml simple)       ; sxml->xml
                #:use-module (guixcfg flatpak model)
                #:use-module (guixcfg flatpak registry)
                #:use-module (guixcfg fonts model) ; %fonts
                #:use-module (guixcfg fonts fontconfig-policy)
                #:use-module (guixcfg system application-persistence) ; application-persistence-rule
                #:use-module (guixcfg utils module-closure) ; guixcfg-module-select?
               #:export (%flatpak-installation-persistence-rule
                         flatpak-application-persistence-rules
                         flatpak-selected-applications
                         flatpak-persistence-rules
                           flatpak-override-files
                           flatpak-override-files* ; overlay-aware
                           flatpak-overrides-activation
                          %flatpak-fontconfig-file
                          %flatpak-global-override-file
                         flatpak-desktop-files
                         flatpak-home-services
                         %flatpak-session-environment-service
                         %flatpak-files-service
                         %flatpak-home-services))

;;; ── persistence rules（data-app 映射，docs/architecture/
;;;    flatpak.md（persistence））────────────────────────────

;; Flatpak user installation 整体（repo/remotes/exports/overrides/
;; runtime 元数据——内部结构由 Flatpak 自己管理，不拆）。平台拥有。
(define %flatpak-installation-persistence-rule
  (application-persistence-rule
   (name 'flatpak-installation)
   (backing "flatpak/installation")        ; /persist/data-app 下相对路径
   (consumer ".local/share/flatpak")       ; HOME 相对（flatpak canonical path）
   (exposure 'bind-directory)
   (lifecycle 'application-owned)))

(define (flatpak-default-persistence-rule app)
  "默认 persistence intent：~/.var/app/<id>（含 sandbox 内
config/data/cache——不做目录白名单，reliability 优先），从
application ID 推导——app 自己拥有这条事实（definition 只需声明
ID，投影在此显式可见）。"
  (application-persistence-rule
   (name (string->symbol (string-append "flatpak-app-"
                                        (flatpak-application-id app))))
   (backing (string-append "flatpak/apps/"
                           (flatpak-application-id app)))
   (consumer (string-append ".var/app/" (flatpak-application-id app)))
   (exposure 'bind-directory)
   (lifecycle 'application-owned)))

(define (flatpak-extra-persistence-rules app)
  "definition 的 extra-persistence（(consumer backing) 两元素
列表；backing 相对 flatpak/apps/ 命名空间）→ rules。默认路径之外
才有此字段。"
  (map (lambda (entry)
         (let ((consumer (car entry))
               (backing (cadr entry)))
           (application-persistence-rule
            (name (string->symbol
                   (string-append "flatpak-app-"
                                  (flatpak-application-id app)
                                  "-" backing)))
            (backing backing)
            (consumer consumer)
            (exposure 'bind-directory)
            (lifecycle 'application-owned))))
       (flatpak-application-extra-persistence app)))

(define (flatpak-application-persistence-rules app)
  "APP 的 persistence intent → rules：默认 ~/.var/app/<id> +
definition 声明的例外。"
  (cons (flatpak-default-persistence-rule app)
        (flatpak-extra-persistence-rules app)))

(define (flatpak-selected-applications)
  "全局 selection（logical names）→ catalog lookup → 完整 definitions。
Flatpak selection 是跨设备一致的用户软件 policy，不再接受 host
selection 参数（docs/architecture/flatpak.md）。"
  (flatpak-select-applications %flatpak-selection
                               %flatpak-applications))

(define* (flatpak-persistence-rules)
         "平台全部 persistence rules：installation + 每个 **selected** app
的 persistence intent。host 组装点把它与 applications-persistence
一起交给 generic engine（file-systems bind + activation backing/
owner）。未选中的 catalog app 不产生 mount（selection 投影）。"
         (cons %flatpak-installation-persistence-rule
               (append-map flatpak-application-persistence-rules
                           (flatpak-selected-applications))))

;;; ── override 完整文件（complete-file ownership）────────────

;; Guix profiles expose fonts through symlinks into /gnu/store.  Flatpak's
;; built-in /run/host/fonts projection cannot resolve those targets, so it
;; falls back to the runtime's smaller font set.  The global override grants
;; only the exact font outputs and this generated config to each sandbox.
(define (fontconfig-sxml->string sxml)
  (call-with-output-string
   (lambda (port)
     (sxml->xml sxml port))))

(define %flatpak-font-packages
  ;; WeChat's Chromium renderer selects the projected msyh.ttc by path and
  ;; clears FONTCONFIG_FILE in its renderer subprocess.  Keep Office fonts in
  ;; host profiles for document compatibility, but do not expose that YaHei
  ;; payload to Flatpaks: MiSans is the intended CJK UI fallback there.
  (filter (lambda (pkg)
            (not (member (package-name pkg)
                         '("fontconfig" "fontconfig-minimal"
                           "font-microsoft-win11-office-core"))))
          %fonts))

;; Flatpak's Fontconfig applies strong <alias> preferences after the runtime
;; defaults, unlike the host configuration.  Replace the generic chain at the
;; pattern stage so every sandbox gets the same family order deterministically.
(define (flatpak-family-chain-edit family chain)
  `(match (@ (target "pattern"))
          (test (@ (qual "any") (name "family") (compare "eq"))
                (string ,family))
          (edit (@ (name "family") (mode "assign_replace") (binding "strong"))
                ,@(map (lambda (entry) (list 'string entry)) chain))))

(define %flatpak-fontconfig-snippets
  ;; This runtime canonicalizes CSS generic names before applying configuration
  ;; rules: "sans-serif" becomes "sans" and "system-ui" becomes "system".
  (list (flatpak-family-chain-edit "sans" %sans-serif-families)
         (flatpak-family-chain-edit "sans-serif" %sans-serif-families)
         (flatpak-family-chain-edit "ui-sans-serif" %sans-serif-families)
         (flatpak-family-chain-edit "system" %sans-serif-families)
         (flatpak-family-chain-edit "system-ui" %sans-serif-families)
         (flatpak-family-chain-edit "Microsoft YaHei" %sans-serif-families)
         (flatpak-family-chain-edit "Microsoft YaHei UI" %sans-serif-families)
         (flatpak-family-chain-edit "微软雅黑" %sans-serif-families)
         (flatpak-family-chain-edit "serif" %serif-families)
         (flatpak-family-chain-edit "mono" %monospace-families)
         (flatpak-family-chain-edit "monospace" %monospace-families)
         (flatpak-family-chain-edit "ui-monospace" %monospace-families)
         (flatpak-family-chain-edit "emoji" '("Noto Color Emoji"))))

(define %flatpak-fontconfig-file
  (apply mixed-text-file
         "guixcfg-flatpak-fonts.conf"
         (append
          (list "<?xml version=\"1.0\"?>\n"
                "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">\n"
                "<fontconfig>\n")
          (append-map (lambda (pkg)
                        (list "<dir>" (file-append pkg "/share/fonts")
                              "</dir>\n"))
                      %flatpak-font-packages)
          (list (fontconfig-sxml->string %flatpak-fontconfig-snippets)
                "</fontconfig>\n"))))

(define %flatpak-global-override-file
  (apply mixed-text-file
         "guixcfg-flatpak-global-override"
         (append
          (list "[Context]\nfilesystems=")
          (append-map (lambda (pkg)
                        (list (file-append pkg "/share/fonts") ":ro;"))
                      %flatpak-font-packages)
          (list %flatpak-fontconfig-file ":ro;\n\n[Environment]\n"
                "FONTCONFIG_FILE=" %flatpak-fontconfig-file "\n"))))

(define (flatpak-override-files apps)
  "APPS 中每个 override-policy = (managed-overrides ...) 的应用 →
home-files 的 (target source) 条目：.local/share/flatpak/overrides/
<app-id> ← 确定性渲染的完整 GKeyFile（plain-file）。'external 的
应用不生成（user/Flatseal owns）。renderer 输出空串时不生成文件。"
  (filter-map
   (lambda (app)
     (let ((managed (flatpak-application-managed-overrides app)))
       (and managed
            (let ((rendered (flatpak-render-override-file managed)))
              (and (not (string-null? rendered))
                   (list (string-append ".local/share/flatpak/overrides/"
                                        (flatpak-application-id app))
                         (plain-file
                          (string-append "flatpak-override-"
                                         (flatpak-application-id app))
                          rendered)))))))
   apps))

(define* (flatpak-override-files* #:key (environment-overrides '()))
         "overlay-aware override 投影：先按全局 selection 解析 definitions，
再应用硬件 adapter 声明的 ENVIRONMENT-OVERRIDES（logical name →
'VAR=VALUE' 列表；仅 managed-overrides app 接受环境 overlay，
external app 与未知 target fail closed）。"
         (flatpak-override-files
          (flatpak-applications-with-environments
           environment-overrides
           (flatpak-selected-applications))))

(define (flatpak-overrides-activation environment-overrides)
  "Return a system activation service that atomically projects managed
Flatpak overrides into the canonical persistent installation backing."
  (let ((entries
         (map (lambda (entry)
                (list (string-drop (car entry)
                                   (string-length
                                    ".local/share/flatpak/overrides/"))
                      (cadr entry)))
               (cons (list ".local/share/flatpak/overrides/global"
                           %flatpak-global-override-file)
                     (flatpak-override-files*
                      #:environment-overrides environment-overrides)))))
    (simple-service
     'flatpak-managed-overrides
     activation-service-type
      (with-imported-modules
       (source-module-closure '((guix build utils)
                                (guixcfg utils atomic-file)
                                (ice-9 rdelim)
                                (ice-9 textual-ports))
                              #:select? guixcfg-module-select?)
       #~(begin
           (use-modules (guix build utils)
                        (guixcfg utils atomic-file)
                        (ice-9 rdelim)
                        (ice-9 textual-ports))
          (let* ((directory "/persist/data-app/flatpak/installation/overrides")
                 (manifest (string-append directory "/.guixcfg-managed"))
                 (current (map car '#$entries)))
            (define (read-managed)
              (if (file-exists? manifest)
                  (call-with-input-file
                      manifest
                    (lambda (port)
                      (let loop ((result '()))
                        (let ((line (read-line port)))
                          (if (eof-object? line)
                              (reverse result)
                              (loop (cons line result)))))))
                  '()))
            (define (safe-id? id)
              (and (string? id)
                   (> (string-length id) 0)
                   (not (string=? id "."))
                   (not (string=? id ".."))
                   (let loop ((index 0))
                     (or (= index (string-length id))
                         (and (not (char=? (string-ref id index) #\/))
                              (loop (1+ index)))))))
            (mkdir-p directory)
            ;; Only entries recorded by the previous activation are ours to
            ;; remove; Flatseal-owned override files are never in this list.
            (for-each
             (lambda (id)
               (unless (safe-id? id)
                 (error "unsafe managed Flatpak override ID in manifest" id))
               (unless (member id current)
                 (false-if-exception
                  (delete-file (string-append directory "/" id)))))
             (read-managed))
            (for-each
             (lambda (entry)
               (atomic-write-file!
                (string-append directory "/" (car entry))
                (lambda (port)
                  (display (call-with-input-file (cadr entry) get-string-all)
                           port))))
             '#$entries)
            (atomic-write-file!
              manifest
              (lambda (port)
                (for-each (lambda (id) (format port "~a~%" id)) current)))))))))

(define (flatpak-desktop-files apps)
  "APPS 的 desktop-files contribution → home-files 条目。definition 只
声明 basename；projection 统一拥有 XDG applications target。"
  (append-map
   (lambda (app)
     (map (lambda (entry)
            (list (string-append ".local/share/applications/" (car entry))
                  (cadr entry)))
          (flatpak-application-desktop-files app)))
   apps))

(define* (flatpak-home-files #:key (environment-overrides '()))
          (flatpak-desktop-files (flatpak-selected-applications)))

(define %flatpak-files-service
  (simple-service 'flatpak-files
                  home-files-service-type
                  (flatpak-home-files)))

(define* (flatpak-home-services #:key (environment-overrides '()))
          "Flatpak 平台 Home services（desktop 完整文件生成 + XDG_DATA_DIRS
exports 追加）。Managed overrides are projected by system activation."
         (list (simple-service 'flatpak-files
                               home-files-service-type
                               (flatpak-home-files #:environment-overrides
                                                   environment-overrides))
               %flatpak-session-environment-service))

;;; ── session env（XDG_DATA_DIRS）────────────────────────────

;; per-user exports 目录追加进 XDG_DATA_DIRS：Noctalia/launcher 经
;; XDG_DATA_DIRS 发现 desktop entries（pinned Guix Home 的
;; setup-environment 只前置 profile share，不含 ~/.local/share）。
;; 追加（而非覆盖）：$XDG_DATA_DIRS 在 source 时展开，preamble 已
;; 保证其非空（至少 Home profile share，保持 Guix 应用优先）。
(define %flatpak-session-environment-service
  (simple-service 'flatpak-session-environment
                  home-environment-variables-service-type
                  '(("XDG_DATA_DIRS"
                     . "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share"))))

(define %flatpak-home-services
  (list %flatpak-files-service
        %flatpak-session-environment-service))
