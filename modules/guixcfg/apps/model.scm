;;; Application layer 模型（docs/architecture/home.md、AGENT.md
;;; §Application layer）：以应用为纵向配置单元。
;;;
;;; <application> 只是 contribution container——它声明这个应用贡献
;;; 哪些 home packages / home services / system services /
;;; persistence rules / secrets；部署、挂载、发布一律由各自的
;;; generic single-owner mechanism 执行（Guix Home、file-systems、
;;; secrets publisher）。
;;;
;;; 明确不是：NixOS/RDE module system。无 dependency solver、
;;; 无 priority、无 override、无自动发现、无继承。启用/禁用必须经
;;; 显式 registry（(guixcfg apps registry)）；目录存在 != 应用启用。

(define-module (guixcfg apps model)
               #:use-module (guix records)
               #:use-module (srfi srfi-1)          ; append-map
               #:export (<application>
                         application make-application application?
                         application-name
                         application-home-packages
                         application-home-services
                         application-system-services
                         application-persistence
                         application-secrets
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
                              (default '())))

(define (applications-home-packages apps)
  "聚合 APPS 的全部 home packages。"
  (append-map application-home-packages apps))

(define (applications-home-services apps)
  "聚合 APPS 的全部 home services——纯 concatenation，无任何
组合逻辑（组合语义归 Guix：共享 target 由 application 经 native
extension 贡献，canonical target 由 instantiate-missing-services
以 default value 自动实例化——AGENT.md §15）。"
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
