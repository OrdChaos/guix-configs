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
               #:use-module (gnu services)          ; service、service-type-extend
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

(define (merge-home-services services)
  "把同 kind 的 home service 合并为单实例。Guix Home 的 extension
图要求被其它服务扩展的 target 类型每类至多一个实例（例如
home-shepherd 自动扩展 home-xdg-configuration-files——多个 xdg
实例会 ambiguous-target-service，实测）。合并使用 service-type
自身的 extend（Guix fold-services 同一语义）；无 extend 的类型
多实例直接报错（不是可合并类型）。"
  ;; SRFI-1 fold 以 (proc elem acc) 调用——elem 在前。
  (define (merge-one s out)
    (let ((k (service-kind s)))
      (if (assq k out)
        (let ((extend (service-type-extend k)))
          (unless extend
                  (error "cannot merge home services without extend"
                         (service-type-name k)))
          (map (lambda (x)
                 ;; out 元素是 (kind . service) pair
                 (if (eq? (service-kind (cdr x)) k)
                   (cons k (service k (extend (service-value (cdr x))
                                              (service-value s))))
                   x))
               out))
        (cons (cons k s) out))))
  (map cdr (fold merge-one '() services)))

(define (applications-home-services apps)
  "聚合 APPS 的全部 home services，并按 kind 合并为单实例
（Guix Home 组合约束——见 merge-home-services）。"
  (merge-home-services (append-map application-home-services apps)))

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
