;;; Generic "extra application configuration files" mechanism
;;; （docs/architecture/applications.md（Host-agnostic boundary））。
;;;
;;; 语义：上层（当前第一个消费者是 host/profile overlay）可以向
;;; 任意 application 的 XDG 配置位置贡献额外的原生配置文件；最终
;;; 由 Guix Home 安装到 ~/.config/<path>。机制本身不表达任何
;;; host/hardware 概念——application 只是贡献的 owner。
;;;
;;;   <extra-configuration-file>：
;;;     application  贡献的 owner（symbol，registry 校验 + ownership/
;;;                  diagnostics）——不隐含任何路径约定；
;;;     path         完整的、相对于 ~/.config 的目标路径
;;;                  （如 "niri/host.kdl"），与 application name
;;;                  无耦合；
;;;     source       file-like，不透明——原生格式（KDL/TOML/...），
;;;                  Scheme 不解析内容。
;;;
;;; 依赖方向（单向；application 不读取上层）：
;;;
;;;   application（app 自身通用配置）
;;;       │
;;;       ▼
;;;   host/profile overlay（经本模块贡献额外原生配置文件）
;;;       │
;;;       ▼
;;;   Guix Home composition（home-xdg-configuration-files sink）
;;;       │
;;;       ▼
;;;   最终 ~/.config/...
;;;
;;; 冲突语义：同一最终 target path 只能有一个 owner。聚合器在组合
;;; 时按 path 查重（fail fast，报出冲突路径与全部贡献的 owner/
;;; 来源）；跨贡献方冲突（如 extra 与 application 自身文件冲突）
;;; 由 Guix Home 的 assert-no-duplicates 在 lower 时兜底报错——
;;; 本模块不重复实现另一套冲突系统。

(define-module (guixcfg apps extra-config)
               #:use-module (gnu home services) ; home-xdg-configuration-files-service-type
               #:use-module (gnu services)      ; simple-service
               #:use-module (guix gexp)         ; local-file?、local-file-name
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg apps registry) ; %applications（app 名校验权威）
               #:use-module (srfi srfi-1)       ; find、assoc
               #:export (extra-configuration-file
                         extra-configuration-file?
                         extra-configuration-file-application
                         extra-configuration-file-path
                         extra-configuration-file-source
                         extra-configuration-files->home-services))

(define-record-type* <extra-configuration-file>
  extra-configuration-file make-extra-configuration-file
  extra-configuration-file?
  (application extra-configuration-file-application) ; symbol：registry 中的应用名（owner）
  (path extra-configuration-file-path)      ; string：~/.config 相对的目标路径
  (source extra-configuration-file-source)) ; file-like：原生格式文件（不透明）

;; path 必须是合法的 ~/.config 相对路径：非空、非绝对、无 ".."
;; 逃逸（与 repository-file 相同的校验规则）。
(define (validate-relative-path! path)
  (unless (and (string? path)
               (> (string-length path) 0)
               (not (string-prefix? "/" path))
               (not (string-contains path "..")))
    (error "extra-configuration-file: invalid target path" path)))

;; registry 名字集（fail fast：对未启用/不存在的应用贡献文件是
;; 配置错误——文件会被安装但没有声明的 owner）。
(define %registered-applications
  (map application-name %applications))

(define (validate-application! app)
  (unless (memq app %registered-applications)
    (error "extra-configuration-file: unknown or disabled application"
           app %registered-applications)))

(define (file-description source)
  "错误消息用的贡献来源描述：local-file 报 store 名，否则报对象
类型（file-like 内容不透明，不解析）。"
  (if (local-file? source)
    (local-file-name source)
    (object->string source)))

(define (extra-configuration-files->home-services extra-files)
  "把 EXTRA-FILES（<extra-configuration-file> 列表）转为
home-xdg-configuration-files-service-type 的 extension 贡献
（返回 service 列表，供 home assembly 直接 append）。

校验：
  1. 每条都是 <extra-configuration-file>；
  2. application 必须已注册（registry 是启用唯一权威；owner 校验）；
  3. path 必须是合法的 ~/.config 相对路径；
  4. 同一最终 target path 最多一个 owner——重复即报错，列出冲突
     路径与全部贡献的 owner/来源（Guix Home 的
     assert-no-duplicates 仍作为跨贡献方冲突的 lower 时兜底）。
"
  (for-each (lambda (f)
              (unless (extra-configuration-file? f)
                (error "extra-configuration-files->home-services: not an \
extra-configuration-file" f))
              (validate-application!
               (extra-configuration-file-application f))
              (validate-relative-path!
               (extra-configuration-file-path f)))
            extra-files)
  ;; 冲突检测：按最终 target path 分组，组内多于一条即冲突。
  (let ((seen (make-hash-table)))
    (for-each (lambda (f)
                (let ((path (extra-configuration-file-path f)))
                  (hash-set! seen path (cons f (hash-ref seen path '())))))
              extra-files)
    (hash-for-each
     (lambda (path contributors)
       (when (pair? (cdr contributors))
         (error "extra-configuration-file: duplicate target path \
(one owner per final path)"
                path
                (map (lambda (f)
                       (list (extra-configuration-file-application f)
                             (extra-configuration-file-path f)
                             (file-description
                              (extra-configuration-file-source f))))
                     contributors))))
     seen))
  (if (null? extra-files)
    '()
    ;; 共享 sink 经 native extension 贡献（AGENT.md §12：不创建第二
    ;; 个完整服务实例；canonical target 由 instantiate-missing-
    ;; services 自动实例化）。条目形态为两元素列表 (target source)
    ;; ——与仓库其它 xdg-config 贡献一致（quasiquote 列表形态；
    ;; home-files 的 assert-no-duplicates 只匹配该形态）。
    (list (simple-service 'extra-configuration-files
                          home-xdg-configuration-files-service-type
                          (map (lambda (f)
                                 (list (extra-configuration-file-path f)
                                       (extra-configuration-file-source f)))
                               extra-files)))))
