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
;;;     (managed-overrides ...) 的 app 由 home-files 生成
;;;     .local/share/flatpak/overrides/<id>（store symlink =
;;;     derived state，随 generation/rollback；complete-file
;;;     ownership，repo 与 Flatseal 永不 merge）；'external →
;;;     不生成（user/Flatseal owns）；
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
               #:use-module (gnu services)      ; simple-service
               #:use-module (guix gexp)         ; plain-file
               #:use-module (srfi srfi-1)       ; filter-map、append-map
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg flatpak registry)
               #:use-module (guixcfg system application-persistence) ; application-persistence-rule
               #:export (%flatpak-installation-persistence-rule
                         flatpak-application-persistence-rules
                         flatpak-selected-applications
                         flatpak-persistence-rules
                         flatpak-override-files
                         %flatpak-session-environment-service
                         %flatpak-overrides-service
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
  "selection（logical names）→ catalog lookup → 完整 definitions。"
  (flatpak-select-applications %flatpak-selection
                               %flatpak-applications))

(define (flatpak-persistence-rules)
  "平台全部 persistence rules：installation + 每个 **selected** app
的 persistence intent。host 组装点把它与 applications-persistence
一起交给 generic engine（file-systems bind + activation backing/
owner）。未选中的 catalog app 不产生 mount（persistence 随
selection 投影）。"
  (cons %flatpak-installation-persistence-rule
        (append-map flatpak-application-persistence-rules
                    (flatpak-selected-applications))))

;;; ── override 完整文件（complete-file ownership）────────────

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

(define %flatpak-overrides-service
  ;; override 与 persistence 使用同一个 selected definitions 事实
  ;; （docs/architecture/flatpak.md）：unselected 的 catalog app 不
  ;; 生成 declarative override 文件（selection 删除后下一 Home
  ;; generation 即清除对应 symlink）。
  (simple-service 'flatpak-overrides
                  home-files-service-type
                  (flatpak-override-files
                   (flatpak-selected-applications))))

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
  (list %flatpak-overrides-service
        %flatpak-session-environment-service))
