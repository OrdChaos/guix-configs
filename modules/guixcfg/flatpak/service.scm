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
;;;   - override 完整文件：definition 的 override-policy 为
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
  #:use-module (gnu home services) ;home-environment-variables-service-type、home-files-service-type
  #:use-module (gnu services) ;simple-service、activation-service-type
  #:use-module (guix gexp) ;plain-file、mixed-text-file、file-append
  #:use-module (guix modules) ;source-module-closure
  #:use-module (srfi srfi-1) ;filter-map、append-map
  #:use-module (guixcfg flatpak model)
  #:use-module (guixcfg flatpak registry)
  #:use-module (guixcfg home appearance) ;%appearance-cursor-theme/size（shared facts）
  #:use-module (guixcfg system application-persistence) ;application-persistence-rule
  #:use-module (guixcfg utils module-closure) ;guixcfg-module-select?
  #:use-module (virelith packages cursors) ;fluent-cursor-theme
  #:export (%flatpak-installation-persistence-rule
            %flatpak-overrides-directory
            %flatpak-global-override-file
            flatpak-application-persistence-rules
            flatpak-selected-applications
            flatpak-persistence-rules
            flatpak-override-files
            flatpak-override-files* ;overlay-aware
            flatpak-overrides-activation
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
  (application-persistence-rule (name 'flatpak-installation)
                                (backing "flatpak/installation") ;/persist/data-app 下相对路径
                                (consumer ".local/share/flatpak") ;HOME 相对（flatpak canonical path）
                                (exposure 'bind-directory)
                                (lifecycle 'application-owned)))

;; overrides 目录是 installation backing 的固定子路径：从 persistence
;; rule + %application-persistence-root 派生，避免在此重复拼写
;; /persist/data-app（AGENTS §13 路径 authority 规则）。
(define %flatpak-overrides-directory
  (string-append %application-persistence-root "/"
                 (application-persistence-rule-backing
                  %flatpak-installation-persistence-rule) "/overrides"))

(define (flatpak-default-persistence-rule app)
  "默认 persistence intent：~/.var/app/<id>（含 sandbox 内
config/data/cache——不做目录白名单，reliability 优先），从
application ID 推导——app 自己拥有这条事实（definition 只需声明
ID，投影在此显式可见）。"
  (application-persistence-rule (name (string->symbol (string-append
                                                       "flatpak-app-"
                                                       (flatpak-application-id
                                                        app))))
                                (backing (string-append "flatpak/apps/"
                                                        (flatpak-application-id
                                                         app)))
                                (consumer (string-append ".var/app/"
                                                         (flatpak-application-id
                                                          app)))
                                (exposure 'bind-directory)
                                (lifecycle 'application-owned)))

(define (flatpak-extra-persistence-rules app)
  "definition 的 extra-persistence（(consumer backing) 两元素
列表；backing 相对 flatpak/apps/ 命名空间）→ rules。默认路径之外
才有此字段。"
  (map (lambda (entry)
         (let ((consumer (car entry))
               (backing (cadr entry)))
           (application-persistence-rule (name (string->symbol (string-append
                                                                "flatpak-app-"
                                                                (flatpak-application-id
                                                                 app) "-"
                                                                backing)))
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
  (flatpak-select-applications %flatpak-selection %flatpak-applications))

(define* (flatpak-persistence-rules)
  "平台全部 persistence rules：installation + 每个 **selected** app
的 persistence intent。host 组装点把它与 applications-persistence
一起交给 generic engine（file-systems bind + activation backing/
owner）。未选中的 catalog app 不产生 mount（selection 投影）。"
  (cons %flatpak-installation-persistence-rule
        (append-map flatpak-application-persistence-rules
                    (flatpak-selected-applications))))

;;; ── override 完整文件（complete-file ownership）────────────

(define (flatpak-override-files apps)
  "APPS 中每个 override-policy = (managed-overrides ...) 的应用 →
home-files 的 (target source) 条目：.local/share/flatpak/overrides/
<app-id> ← 确定性渲染的完整 GKeyFile（plain-file）。'external 的
应用不生成（user/Flatseal owns）。renderer 输出空串时不生成文件。"
  (filter-map (lambda (app)
                (let ((managed (flatpak-application-managed-overrides app)))
                  (and managed
                       (let ((rendered (flatpak-render-override-file managed)))
                         (and (not (string-null? rendered))
                              (list (string-append
                                     ".local/share/flatpak/overrides/"
                                     (flatpak-application-id app))
                                    (plain-file (string-append
                                                 "flatpak-override-"
                                                 (flatpak-application-id app))
                                                rendered))))))) apps))

(define* (flatpak-override-files* #:key (environment-overrides '()))
  "overlay-aware override 投影：先按全局 selection 解析 definitions，
再应用硬件 adapter 声明的 ENVIRONMENT-OVERRIDES（logical name →
'VAR=VALUE' 列表；仅 managed-overrides app 接受环境 overlay，
external app 与未知 target fail closed）。"
  (flatpak-override-files (flatpak-applications-with-environments
                           environment-overrides
                           (flatpak-selected-applications))))

;;; ── 全局 override（overrides/global）────────────────────────
;;; X11（XWayland）应用在客户端经 libXcursor 解析光标主题，读
;;; XCURSOR_PATH/XCURSOR_THEME。Flatpak 会转发 XCURSOR_THEME/XCURSOR_SIZE
;;; 但【丢弃 XCURSOR_PATH】，且不暴露宿主 profile 的 share/icons（只提供
;;; /run/host/fonts 与 runtime 的 /usr/share/icons/hicolor）——因此沙箱内
;;; X11 应用找不到 Fluent 主题，回退为默认黑色光标；原生 XWayland 应用
;;; 因宿主环境完整而正常。
;;;
;;; 修复：overrides/global 是 Flatpak 的全局 override（作用于全部应用，
;;; 含 'external/user-owned 的应用——它们没有 managed override 文件）。
;;; 只读暴露光标主题目录并把 XCURSOR_PATH 指向它（同时显式固定
;;; XCURSOR_THEME/SIZE，使沙箱不依赖宿主 session env）。主题目录随
;;; store 路径嵌入本文件 derivation，是 system closure 的输入（GC 安全）。
(define %flatpak-cursor-theme-bundle
  (computed-file "flatpak-cursor-theme-bundle"
                 (with-imported-modules '((guix build utils))
                                        #~(begin
                                            (use-modules (guix build utils))
                                            (let ((out #$output)
                                                  (theme #$(file-append
                                                            fluent-cursor-theme
                                                            "/share/icons/Fluent-dark-cursors")))
                                              (copy-recursively theme
                                                                (string-append
                                                                 out
                                                                 "/Fluent-dark-cursors"))
                                              ;; Chromium 的光标主题名优先级是 LinuxUi(GTK) → Xcursor.theme
                                              ;; → "default"；沙箱内 GTK 默认返回 "Adwaita"。把常见回退名
                                              ;; 软链到配置主题，避免回落到核心黑色字体指针。
                                              (for-each (lambda (name)
                                                          (symlink
                                                           "Fluent-dark-cursors"
                                                           (string-append out
                                                            "/" name)))
                                                        '("default" "Adwaita")))))))

(define %flatpak-global-override-file
  (mixed-text-file "flatpak-global-override"
   "# (guixcfg flatpak service) global override for ALL apps (incl. 'external).
"
   "# X11/XWayland apps resolve the cursor theme client-side; expose it here.
"
   "[Context]\n"
   "filesystems="
   %flatpak-cursor-theme-bundle
   ":ro;\n"
   "\n"
   "[Environment]\n"
   "XCURSOR_THEME="
   %appearance-cursor-theme
   "\n"
   "XCURSOR_SIZE="
   (number->string %appearance-cursor-size)
   "\n"
   "XCURSOR_PATH="
   %flatpak-cursor-theme-bundle
   "\n"))

(define* (flatpak-overrides-activation environment-overrides
                                       #:key (global-override
                                              %flatpak-global-override-file))
  "Return a system activation service that atomically projects managed
Flatpak overrides (plus the platform GLOBAL-OVERRIDE, applied to every app)
into the canonical persistent installation backing."
  (let ((entries (map (lambda (entry)
                        (list (string-drop (car entry)
                                           (string-length
                                            ".local/share/flatpak/overrides/"))
                              (cadr entry)))
                      (flatpak-override-files* #:environment-overrides
                                               environment-overrides))))
    (simple-service 'flatpak-managed-overrides activation-service-type
                    (with-imported-modules (source-module-closure '((guix
                                                                     build
                                                                     utils)
                                                                    (guixcfg
                                                                     utils
                                                                     atomic-file)
                                                                    (ice-9
                                                                     rdelim)
                                                                    (ice-9
                                                                     textual-ports))
                                            #:select? guixcfg-module-select?)
                                           #~(begin
                                               (use-modules (guix build utils)
                                                            (guixcfg utils
                                                             atomic-file)
                                                            (ice-9 rdelim)
                                                            (ice-9
                                                             textual-ports))
                                               (let* ((directory #$%flatpak-overrides-directory)
                                                      (manifest (string-append
                                                                 directory
                                                                 "/.guixcfg-managed"))
                                                      ;; 全局 override 单独处理：其 file-like 经【非引号】gexp
                                                      ;; 注入（store path），避免把带 store 路径的 computed
                                                      ;; 文件塞进被 quote 的 entries（会引入非确定性）。
                                                      (global-file #$global-override)
                                                      (current (append (map
                                                                        car
                                                                        '#$entries)
                                                                       (list
                                                                        "global"))))
                                                 (define (read-managed)
                                                   (if (file-exists? manifest)
                                                       (call-with-input-file manifest
                                                         (lambda (port)
                                                           (let loop
                                                             ((result '()))
                                                             (let ((line (read-line
                                                                          port)))
                                                               (if (eof-object?
                                                                    line)
                                                                   (reverse
                                                                    result)
                                                                   (loop (cons
                                                                          line
                                                                          result)))))))
                                                       '()))
                                                 (define (safe-id? id)
                                                   (and (string? id)
                                                        (> (string-length id)
                                                           0)
                                                        (not (string=? id "."))
                                                        (not (string=? id ".."))
                                                        (let loop
                                                          ((index 0))
                                                          (or (= index
                                                                 (string-length
                                                                  id))
                                                              (and (not (char=?
                                                                         (string-ref
                                                                          id
                                                                          index)
                                                                         #\/))
                                                                   (loop (1+
                                                                          index)))))))
                                                 (mkdir-p directory)
                                                 ;; Only entries recorded by the previous activation are ours to
                                                 ;; remove; Flatseal-owned override files are never in this list.
                                                 (for-each (lambda (id)
                                                             (unless (safe-id?
                                                                      id)
                                                               (error
                                                                "unsafe managed Flatpak override ID in manifest"
                                                                id))
                                                             (unless (member
                                                                      id
                                                                      current)
                                                               (false-if-exception
                                                                (delete-file (string-append
                                                                              directory
                                                                              "/"
                                                                              id)))))
                                                           (read-managed))
                                                 (for-each (lambda (entry)
                                                             (atomic-write-file!
                                                              (string-append
                                                               directory "/"
                                                               (car entry))
                                                              (lambda (port)
                                                                (display (call-with-input-file 
                                                                                               (cadr
                                                                                                entry)
                                                                           get-string-all)
                                                                         port))))
                                                           '#$entries)
                                                 (atomic-write-file! (string-append
                                                                      directory
                                                                      "/global")
                                                                     (lambda (port)
                                                                       (display (call-with-input-file global-file
                                                                                  get-string-all)
                                                                        port)))
                                                 (atomic-write-file! manifest
                                                                     (lambda (port)
                                                                       (for-each (lambda 
                                                                                         (id)
                                                                                   
                                                                                   (format
                                                                                    port
                                                                                    "~a~%"
                                                                                    id))
                                                                        current)))))))))

(define (flatpak-desktop-files apps)
  "APPS 的 desktop-files contribution → home-files 条目。definition 只
声明 basename；projection 统一拥有 XDG applications target。"
  (append-map (lambda (app)
                (map (lambda (entry)
                       (list (string-append ".local/share/applications/"
                                            (car entry))
                             (cadr entry)))
                     (flatpak-application-desktop-files app))) apps))

(define* (flatpak-home-files #:key (environment-overrides '()))
  (flatpak-desktop-files (flatpak-selected-applications)))

(define %flatpak-files-service
  (simple-service 'flatpak-files home-files-service-type
                  (flatpak-home-files)))

(define* (flatpak-home-services #:key (environment-overrides '()))
  "Flatpak 平台 Home services（desktop 完整文件生成 + XDG_DATA_DIRS
exports 追加）。Managed overrides are projected by system activation."
  (list (simple-service 'flatpak-files home-files-service-type
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
                  '(("XDG_DATA_DIRS" . "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share"))))

(define %flatpak-home-services
  (list %flatpak-files-service %flatpak-session-environment-service))
