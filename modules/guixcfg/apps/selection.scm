;;; Generic application configuration variant selection
;;; （docs/architecture/applications.md（Host-agnostic boundary））。
;;;
;;; 职责边界：
;;;
;;;   application     拥有配置资源与 variant 声明
;;;                   （<application-configuration-variant>，model.scm）
;;;   host/profile    只做 logical selection——按 application 名 +
;;;                   logical variant 名选择，不接触文件/路径
;;;   generic 层      解析 selection → 校验 → 聚合为 home-files
;;;                   贡献（target 加 ".config/" 前缀）
;;;
;;; <application-configuration-selection> 只携带：
;;;   application   symbol：registry 中的应用名（启用唯一权威）
;;;   variant       symbol：该应用声明的 logical variant 名
;;; host 不知道 variant 对应什么文件、最终 target 路径、source 在
;;; 哪里——改变 variant 背后的文件/路径不要求修改 selection。
;;; application 不反向读取 host。
;;;
;;; 冲突语义：同一最终 target path 只能有一个 owner。resolver 在
;;; 解析后按 target 查重（fail fast，报出冲突路径与全部来源——
;;; application + variant）；跨贡献方冲突（如 variant 与 application
;;; 自身文件冲突）由 Guix Home 的 assert-no-duplicates 在 lower 时
;;; 兜底报错——本模块不重复实现另一套冲突系统。

(define-module (guixcfg apps selection)
               #:use-module (gnu home services) ; home-files-service-type
               #:use-module (gnu services)      ; simple-service
               #:use-module (guix gexp)         ; local-file?、local-file-name
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg apps registry) ; %applications（app 名校验权威）
               #:use-module (srfi srfi-1)       ; find、append-map
               #:export (application-configuration-selection
                         application-configuration-selection?
                         application-configuration-selection-application
                         application-configuration-selection-variant
                         application-configuration-selections->home-services))

(define-record-type* <application-configuration-selection>
                     application-configuration-selection make-application-configuration-selection
                     application-configuration-selection?
                     (application application-configuration-selection-application) ; symbol
                     (variant application-configuration-selection-variant))       ; symbol

;; target 必须是合法的 ~/.config 相对路径：非空、非绝对、无 ".."
;; 逃逸（与 repository-file 相同的校验规则）。
(define (validate-relative-path! target)
  (unless (and (string? target)
               (> (string-length target) 0)
               (not (string-prefix? "/" target))
               (not (string-contains target "..")))
    (error "application-configuration-selection: invalid target path"
           target)))

;; registry 名字集（fail fast：对未启用/不存在的应用做 selection 是
;; 配置错误——文件会被安装但没有声明的 owner/消费者）。
(define (registered-applications apps)
  (map application-name apps))

(define (validate-application! app apps)
  (unless (memq app (registered-applications apps))
    (error "application-configuration-selection: unknown or disabled application"
           app (registered-applications apps))))

(define (find-application app apps)
  (or (find (lambda (a) (eq? app (application-name a))) apps)
      (error "application-configuration-selection: unknown or disabled application"
             app (registered-applications apps))))

(define (find-variant! app-var variant)
  (or (find (lambda (v)
              (eq? variant (application-configuration-variant-name v)))
            (application-configuration-variants app-var))
      (error "application-configuration-selection: application declares no \
such configuration variant"
             (application-name app-var)
             variant
             (map application-configuration-variant-name
                  (application-configuration-variants app-var)))))

(define (file-description source)
  "错误消息用的来源描述：local-file 报 store 名，否则报对象类型
（file-like 内容不透明，不解析）。"
  (if (local-file? source)
    (local-file-name source)
    (object->string source)))

;; 解析结果条目：(target source app variant)——source 描述用于冲突
;; 诊断，app/variant 用于报出 selection 来源。
(define (resolve-selection sel apps)
  (let* ((app (application-configuration-selection-application sel))
         (variant (application-configuration-selection-variant sel))
         (app-var (find-application app apps))
         (decl (find-variant! app-var variant)))
    (map (lambda (entry)
           (let ((target (car entry))
                 (source (cadr entry)))
             (validate-relative-path! target)
             (list target source app variant)))
         (application-configuration-variant-files decl))))

(define* (application-configuration-selections->home-services selections
                                                              #:key (apps %applications))
         "把 SELECTIONS（<application-configuration-selection> 列表）解析为
home-files-service-type 的 extension 贡献（target 加 \".config/\"
前缀；返回 service 列表，供 home assembly 直接 append）。APPS 默认
是 registry 的 %applications（启用唯一权威）；可参数化注入（测试/
组合）。

流程：selection → lookup application（registry）→ lookup 声明
variant → resolve files → 校验 target → 冲突检测 → 聚合。

校验：
  1. 每条都是 <application-configuration-selection>；
  2. application 必须已注册（registry 是启用唯一权威）；
  3. variant 必须由该 application 声明（错误消息含 application +
     variant 与可选项列表）；
  4. target 必须是安全的 ~/.config 相对路径；
  5. 同一最终 target path 只能有一个 owner——重复即报错，列出冲突
     路径与全部来源（application + variant + source 描述；Guix
     Home 的 assert-no-duplicates 仍作为跨贡献方冲突的 lower 兜底）。
"
         (for-each (lambda (sel)
                     (unless (application-configuration-selection? sel)
                       (error "application-configuration-selections->home-services: \
not an application-configuration-selection" sel))
                     (validate-application!
                      (application-configuration-selection-application sel)
                      apps))
                   selections)
         (let* ((entries (append-map (lambda (sel) (resolve-selection sel apps))
                                     selections))
                (seen (make-hash-table)))
           ;; 冲突检测：按最终 target path 分组，组内多于一条即冲突。
           (for-each (lambda (e)
                       (let ((target (car e)))
                         (hash-set! seen target (cons e (hash-ref seen target '())))))
                     entries)
           (hash-for-each
            (lambda (target contributors)
              (when (pair? (cdr contributors))
                (error "application-configuration-selection: duplicate target \
path (one owner per final path)"
                       target
                       (map (lambda (e)
                              (list (caddr e)   ; application
                                    (cadddr e)  ; variant
                                    (file-description (cadr e))))
                            contributors))))
            seen)
           (if (null? entries)
             '()
             ;; 共享 sink 经 native extension 贡献（AGENT.md §12：不创建
             ;; 第二个完整服务实例；canonical target 由
             ;; instantiate-missing-services 自动实例化）。条目形态为两元素
             ;; 列表 (target source)——variant 声明的 target 是 ~/.config
             ;; 相对路径，聚合时加 ".config/" 前缀（与仓库其它
             ;; home-files 贡献一致；quasiquote 列表形态；home-files
             ;; 的 assert-no-duplicates 只匹配该形态）。
             (list (simple-service 'application-configuration-files
                                   home-files-service-type
                                   (map (lambda (e) (list (string-append ".config/" (car e))
                                                          (cadr e)))
                                        entries))))))
