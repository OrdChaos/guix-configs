;;; Application layer 模型（docs/architecture/home.md、AGENT.md
;;; §Application layer）：以应用为纵向配置单元。
;;;
;;; <application> 只是 contribution container——它声明这个应用贡献
;;; 哪些 home packages / home services / system services /
;;; persistence rules / secrets / configuration variants；部署、
;;; 挂载、发布一律由各自的 generic single-owner mechanism 执行
;;; （Guix Home、file-systems、secrets publisher、selection
;;; resolver）。
;;;
;;; <application-configuration-variant>：application 自己声明的可选
;;; 配置变体（如 'laptop）——application 拥有配置资源与 variant
;;; 声明；host/profile 只做 logical selection（(guixcfg apps
;;; selection)），不接触文件/路径（docs/architecture/applications.md
;;; （Host-agnostic boundary））。
;;;
;;; 明确不是：NixOS/RDE module system。无 dependency solver、
;;; 无 priority、无 override、无自动发现、无继承。启用/禁用必须经
;;; 显式 registry（(guixcfg apps registry)）；目录存在 != 应用启用。

(define-module (guixcfg apps model)
               #:use-module (guix records)
               #:use-module (gnu services)       ; service-kind、service-value
               #:use-module (srfi srfi-1)          ; append-map
               #:export (<application>
                         application make-application application?
                         application-name
                         application-home-packages
                         application-home-services
                         application-system-services
                         application-persistence
                         application-secrets
                         application-configuration-variants
                         <application-configuration-variant>
                         application-configuration-variant
                         make-application-configuration-variant
                         application-configuration-variant?
                         application-configuration-variant-name
                         application-configuration-variant-files
                         applications-home-packages
                         applications-home-services
                         applications-system-services
                         applications-persistence
                         applications-secrets))

(define-record-type* <application> application make-application
                     application?
                     (name application-name)                    ; symbol
                     (home-packages application-home-packages   ; list of package
                                    (default '()))
                     (home-services application-home-services   ; list of service
                                    (default '()))
                     (system-services application-system-services ; list of service
                                      (default '()))
                     (persistence application-persistence       ; list of <application-persistence-rule>
                                  (default '()))
                     (secrets application-secrets               ; list of <secret-decl>
                              (default '()))
                     (configuration-variants
                      application-configuration-variants        ; list of <application-configuration-variant>
                      (default '())))

;; 可选配置变体声明（application-owned）：NAME 是稳定 logical
;; identifier（如 'laptop）；FILES 是 (target source) 两元素列表
;; 的集合——target 为完整 ~/.config 相对路径（与 application name
;; 无耦合），source 为 opaque file-like（原生格式，generic 层不
;; 解析）。
(define-record-type* <application-configuration-variant>
                     application-configuration-variant make-application-configuration-variant
                     application-configuration-variant?
                     (name application-configuration-variant-name)     ; symbol
                     (files application-configuration-variant-files))  ; list of (target source)

(define (applications-home-packages apps)
  "聚合 APPS 的全部 home packages。"
  (append-map application-home-packages apps))

;; ── home-files 目标契约（docs/development/applications.md
;; （文件归属 service 选择规则））──────────────────────────────
;; 2026-08 规则反转：~/.config 目标一律经 home-files-service-type
;; 显式带 ".config/" 前缀（home-xdg-configuration-files-service-type
;; 已被 pinned Guix 标记 deprecated，且其语义本就是 home-files 的
;; .config 前缀包装——迁移零语义差）。聚合保持纯 concatenation，
;; 无任何目标校验/合并逻辑。

(define (applications-home-services apps)
  "聚合 APPS 的全部 home services——纯 concatenation，无任何
组合逻辑（组合语义归 Guix：共享 target 由 application 经 native
extension 贡献，canonical target 由 instantiate-missing-services
以 default value 自动实例化——AGENT.md §12）。"
  (append-map application-home-services apps))

(define (applications-system-services apps)
  "聚合 APPS 的全部 system services。"
  (append-map application-system-services apps))

(define (applications-persistence apps)
  "聚合 APPS 的全部 application persistence rules。"
  (append-map application-persistence apps))

(define (applications-secrets apps)
  "聚合 APPS 的全部 secret declarations（ciphertext source 已由
application definition 解析为 file-like）。"
  (append-map application-secrets apps))
