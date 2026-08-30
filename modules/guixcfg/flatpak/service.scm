;;; Flatpak 平台 Home/System 集成（docs/architecture/flatpak.md）。
;;;
;;; 本模块只做【离线生成式】集成——不 import (guixcfg flatpak
;;; reconcile)、不产生任何 flatpak CLI 调用（composition 测试静态
;;; 断言；网络边界不变量）：
;;;   - session env：XDG_DATA_DIRS 追加 per-user exports 目录
;;;     （home-environment-variables-service-type 共享 sink 的
;;;     native extension；追加不覆盖——pinned setup-environment 的
;;;     preamble 先置 Home profile share，本值经 shell-double-quote
;;;     发射（$ 保留）在 source 时展开 $XDG_DATA_DIRS）；
;;;   - override 完整文件：有 declaration 的 app 由 home-files
;;;     生成 .local/share/flatpak/overrides/<id>（store symlink =
;;;     derived state，随 generation/rollback；complete-file
;;;     ownership，repo 与 Flatseal 永不 merge）；无声明 → 不生成
;;;     （user/Flatseal owns）；
;;;   - persistence rules：installation（平台拥有）+ 每 Catalog app
;;;     （apps/<id> backing）——从 Catalog 派生，与 selection
;;;     无关。全部 mount/activation 经 (guixcfg system
;;;     application-persistence) generic engine 执行（host 组装点
;;;     调用 flatpak-persistence-rules），零 Flatpak 专属 mount
;;;     代码；installation 与 apps/<id> 为平级 backing（regression
;;;     测试固定 parent/child 嵌套禁止）。

(define-module (guixcfg flatpak service)
               #:use-module (gnu home services) ; home-environment-variables-service-type、home-files-service-type
               #:use-module (gnu services)      ; simple-service
               #:use-module (guix gexp)         ; plain-file
               #:use-module (srfi srfi-1)       ; filter-map
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg flatpak registry)
               #:use-module (guixcfg system application-persistence) ; application-persistence-rule
               #:export (%flatpak-installation-persistence-rule
                         flatpak-application-persistence-rule
                         flatpak-application-persistence-rules
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

(define (flatpak-application-persistence-rule app)
  "Catalog app 的 userdata rule：~/.var/app/<id> 整体（含 sandbox
内 cache——不做目录白名单，reliability 优先）。app 自己拥有。"
  (application-persistence-rule
   (name (string->symbol (string-append "flatpak-app-"
                                        (flatpak-application-id app))))
   (backing (string-append "flatpak/apps/"
                           (flatpak-application-id app)))
   (consumer (string-append ".var/app/" (flatpak-application-id app)))
   (exposure 'bind-directory)
   (lifecycle 'application-owned)))

(define (flatpak-application-persistence-rules apps)
  "Catalog 每 app 一条 rule（从 Catalog 派生——selection removal
不撕 bind；docs/architecture/flatpak.md（lifecycle））。"
  (map flatpak-application-persistence-rule apps))

(define (flatpak-persistence-rules)
  "平台全部 persistence rules：installation + 每 Catalog app。
host 组装点把它与 applications-persistence 一起交给 generic
engine（file-systems bind + activation backing/owner）。"
  (cons %flatpak-installation-persistence-rule
        (flatpak-application-persistence-rules %flatpak-applications)))

;;; ── override 完整文件（complete-file ownership）────────────

(define (flatpak-override-files apps)
  "APPS（Catalog）中每个有 override 声明的 app → home-files 的
(target source) 条目：.local/share/flatpak/overrides/<app-id> ←
确定性渲染的完整 GKeyFile（plain-file）。无声明的 app 不生成
（user/Flatseal owns）。renderer 输出空串时不生成文件。"
  (filter-map
   (lambda (app)
     (let ((overrides (flatpak-application-overrides app)))
       (and overrides
            (let ((rendered (flatpak-render-override-file overrides)))
              (and (not (string-null? rendered))
                   (list (string-append ".local/share/flatpak/overrides/"
                                        (flatpak-application-id app))
                         (plain-file
                          (string-append "flatpak-override-"
                                         (flatpak-application-id app))
                          rendered)))))))
   apps))

(define %flatpak-overrides-service
  (simple-service 'flatpak-overrides
                  home-files-service-type
                  (flatpak-override-files %flatpak-applications)))

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
