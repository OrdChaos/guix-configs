;;; Mihomo subscription source declarations（SCM 是源清单的 authority）。
;;;
;;; 每个 <mihomo-source> 对应**一个 age 文件**，明文内容只能是：
;;;   - kind = 'http：一个 http(s) URL；
;;;   - kind = 'file：一份 mihomo provider YAML（含 proxies:）。
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
;;;
;;; routing：
;;;   - 'domain：机场/普通订阅。私网直连 + Loyalsoldier 国内直连/国外
;;;     proxy + MATCH,PROXY；
;;;   - 'protocol：专用 edge 订阅。UDP → UDP-HY2 组，TCP → TCP-REALITY
;;;     组；组用 active provider 的固定 filter 选择节点。
;;; 机场默认 'domain；不要对机场开 'protocol（机场节点不保证存在
;;; Hysteria2/Reality，也不保证 UDP 能力）。

(define-module (guixcfg system mihomo sources)
  #:use-module (guix gexp) ;local-file
  #:use-module (srfi srfi-1) ;find
  #:use-module (srfi srfi-9) ;define-record-type
  #:export (<mihomo-source>
            mihomo-source?
            mihomo-source
            mihomo-source-name
            mihomo-source-kind
            mihomo-source-secret-file
            mihomo-source-target-name
            %mihomo-sources
            %mihomo-routing-mode
            %mihomo-protocol-source
            %mihomo-protocol-udp-filter
            %mihomo-protocol-tcp-filter))

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

;; ── routing profile ─────────────────────────────────────────
;; 机场默认 domain；切到 edge 专用协议分流时改成 'protocol，并确保
;; %mihomo-sources 中存在 %mihomo-protocol-source。
(define %mihomo-routing-mode 'domain)

;; protocol 模式使用哪个源作为 UDP/TCP 节点提供者。
(define %mihomo-protocol-source "edge")

;; 节点名 filter（mihomo regex；对 provider 里的节点名匹配）。
(define %mihomo-protocol-udp-filter "^Hysteria2$")
(define %mihomo-protocol-tcp-filter "^Reality$")

(define %mihomo-sources
  (list
   ;; 当前机场源：一个 URL age 文件。
   (mihomo-source "kuromis" 'http
                  (local-file "secrets/kuromis.age" "kuromis.age"))

   ;; edge 文件源示例：age 明文是一份 provider YAML，包含
   ;; Hysteria2/Reality 节点；启用 protocol 模式前取消注释并改
   ;; %mihomo-routing-mode 为 'protocol。
   ;; (mihomo-source "edge" 'file
   ;;                (local-file "secrets/edge.file.age" "edge.file.age"))

   ;; 第二个 HTTP 源示例：
   ;; (mihomo-source "backup" 'http
   ;;                (local-file "secrets/backup.url.age" "backup.url.age"))
   ))

(validate-sources %mihomo-sources)
(unless (memq %mihomo-routing-mode '(domain protocol))
  (error "invalid mihomo routing mode" %mihomo-routing-mode))
(when (eq? %mihomo-routing-mode 'protocol)
  (unless (find (lambda (source)
                  (string=? (mihomo-source-name source)
                            %mihomo-protocol-source))
                %mihomo-sources)
    (error "protocol routing source is not declared"
           %mihomo-protocol-source)))
