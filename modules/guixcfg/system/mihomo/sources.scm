;;; Mihomo subscription source declarations（SCM 是源清单的 authority）。
;;;
;;; 每个 <mihomo-source> 对应**一个 age 文件**，明文内容只能是：
;;;   - kind = 'http：一个 http(s) URL；
;;;   - kind = 'file：一份 mihomo provider YAML（含 proxies:）。
;;;
;;; 每个源生成一个 provider + 一个 SRC-<name> 子策略组；顶层 PROXY
;;; 选择这些 SRC-* 子组作为提供方。
;;;
;;; 新增源：
;;;   1. 创建 age 密文（单个 URL 或单个 provider 文件内容）放到
;;;      mihomo/secrets/；
;;;   2. 在 %mihomo-sources 里加一条 mihomo-source（显式给出 age 文件）；
;;;   3. reconfigure / herd restart mihomo。
;;;
;;; target-name 是 secret 发布路径的稳定名；不写时按 name/kind 派生：
;;;   http → mihomo-source-<name>.url
;;;   file → mihomo-source-<name>.file

(define-module (guixcfg system mihomo sources)
  #:use-module (guix gexp) ;local-file
  #:use-module (srfi srfi-9) ;define-record-type
  #:export (<mihomo-source>
            mihomo-source?
            mihomo-source
            mihomo-source-name
            mihomo-source-kind
            mihomo-source-secret-file
            mihomo-source-target-name
            %mihomo-sources))

(define-record-type <mihomo-source>
  (make-mihomo-source name kind secret-file target-name)
  mihomo-source?
  (name mihomo-source-name)
  (kind mihomo-source-kind)
  (secret-file mihomo-source-secret-file)
  (target-name mihomo-source-target-name))

(define* (mihomo-source name kind secret-file #:optional target-name)
  "声明一个订阅源。KIND 为 'http（明文 URL）或 'file（明文 provider
YAML 内容）；SECRET-FILE 是该源对应的 age 密文 local-file。TARGET-NAME
不写时由 name/kind 派生，通常不需要显式给出。"
  (make-mihomo-source
   name
   kind
   secret-file
   (or target-name
       (string-append "mihomo-source-" name
                      (if (eq? kind 'http) ".url" ".file")))))

(define (validate-sources sources)
  (when (null? sources)
    (error "%mihomo-sources must contain at least one source"))
  (let loop
    ((rest sources)
     (names '())
     (targets '()))
    (unless (null? rest)
      (let* ((source (car rest))
             (name (mihomo-source-name source))
             (kind (mihomo-source-kind source))
             (target (mihomo-source-target-name source)))
        (unless (memq kind '(http file))
          (error "mihomo source has invalid kind" name kind))
        (unless (and (string? name) (> (string-length name) 0))
          (error "mihomo source has empty name"))
        (when (member name names)
          (error "duplicate mihomo source name" name))
        (unless (and (string? target) (> (string-length target) 0))
          (error "mihomo source has empty target-name" name))
        (when (member target targets)
          (error "duplicate mihomo source target-name" target))
        (loop (cdr rest)
              (cons name names)
              (cons target targets))))))

(define %mihomo-sources
  (list
   ;; 机场 HTTP 订阅。
   (mihomo-source "kuromis" 'http
                  (local-file "secrets/kuromis.http.age" "kuromis.http.age"))

   ;; 本地 provider：age 明文是一份 provider YAML。
   (mihomo-source "edge" 'file
                  (local-file "secrets/ordchaos-edge.file.age" "ordchaos-edge.file.age"))

   ;; 第二个 HTTP 源示例：
   ;; (mihomo-source "backup" 'http
   ;;                (local-file "secrets/backup.url.age" "backup.url.age"))
   ))

(validate-sources %mihomo-sources)
