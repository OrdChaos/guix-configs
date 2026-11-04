;;; Mihomo runtime config composition（纯逻辑，无 gnu/guix imports）：
;;; 公开模板 + subscription manifest 原文 → 完整 runtime config 文本。
;;;
;;; 与 (guixcfg system mihomo service) 分离的原因：materializer program-file
;;; 经 source-module-closure 导入本模块（#:select?
;;; guixcfg-module-select?）——保持闭包最小（srfi/match only），
;;; 避免把 gnu/services 依赖拖进 generated runtime（AGENT.md §3
;;; 符号审计面）。
;;;
;;; secret manifest 契约（docs/architecture/mihomo.md）：
;;;   - 单行 URL（旧格式）：自动成为 airport 源；
;;;   - 多行 name=value：value 为 http(s) URL 或绝对文件路径；
;;;   - 空行与 # 注释忽略；name 只允许字母/数字/下划线/连字符；
;;;   - 每个源生成一个 proxy-provider 和一个 SRC-<name> select 组；
;;;   - 顶层 PROXY select 组包含所有 SRC-<name> 与 DIRECT；
;;;   - 文件源使用 mihomo proxy-provider `type: file`；
;;;   - 远端源缓存到 ./providers/<name>.yaml，interval 3600s。
;;;
;;; 运行时路径契约（single-owner constants）：secret 路径必须与
;;; (guixcfg security secrets) 的 runtime-secret-target 派生一致——
;;; ordinary domain + scope system + target-name
;;; "mihomo-subscription.url"（decl 由
;;; (guixcfg system mihomo service) 的 %mihomo-secrets 声明）。target-name
;;; 是历史兼容名；文件内容现在是 manifest。

(define-module (guixcfg system mihomo config)
  #:use-module (srfi srfi-13) ;string-*、string-join
  #:use-module (ice-9 string-fun) ;string-replace-substring
  #:use-module (ice-9 match)
  #:export (%mihomo-proxy-providers-placeholder
            %mihomo-proxy-groups-placeholder
            %mihomo-nm-dnsmasq-uid-placeholder
            %mihomo-secret-path
            %mihomo-runtime-dir
            %mihomo-runtime-config-path
            %mihomo-file-subscriptions-dir
            compose-mihomo-config
            count-substring))

(define %mihomo-proxy-providers-placeholder
  "@@MIHOMO_PROXY_PROVIDERS@@")

(define %mihomo-proxy-groups-placeholder
  "@@MIHOMO_PROXY_GROUPS@@")

;; NetworkManager dnsmasq 的稳定 UID 占位符。
(define %mihomo-nm-dnsmasq-uid-placeholder
  "@@MIHOMO_NM_DNSMASQ_UID@@")

(define %mihomo-secret-path
  "/run/guixcfg-secrets-ordinary/system/mihomo-subscription.url")

(define %mihomo-runtime-dir
  "/run/mihomo")

(define %mihomo-runtime-config-path
  "/run/mihomo/config.yaml")

;; mihomo 的 -d 数据目录；file provider 的 path 必须在它下面（mihomo
;; 的 SAFE_PATHS 检查），否则运行时会拒绝加载。
(define %mihomo-data-directory
  "/var/lib/clash")

;; 文件订阅源的推荐目录；manifest 里也可以写该目录下的其他路径。
(define %mihomo-file-subscriptions-dir
  "/var/lib/clash/subscriptions")

(define (count-substring s sub)
  "SUB 在 S 中出现的次数（SRFI-13 string-contains 循环；不依赖
string-count——它只数字符不数子串）。"
  (let loop
    ((start 0)
     (n 0))
    (let ((i (string-contains s sub start)))
      (if i
          (loop (+ i
                   (string-length sub))
                (+ n 1)) n))))

(define (strip-one-trailing-newline s)
  "移除 S 末尾的【单个】LF 或 CRLF（age 解密产物常见尾换行）。"
  (cond
    ((string-suffix? "\r\n" s)
     (string-drop-right s 2))
    ((string-suffix? "\n" s)
     (string-drop-right s 1))
    (else s)))

(define (yaml-double-quote-escape s)
  "严格 YAML 双引号转义：反斜杠、双引号；tab 一并转义。"
  (let loop
    ((chars (string->list s))
     (out '()))
    (match chars
      (() (list->string (reverse out)))
      ((#\\ . rest) (loop rest
                          (cons* #\\ #\\ out)))
      ((#\" . rest) (loop rest
                          (cons* #\" #\\ out)))
      ((#\tab . rest) (loop rest
                            (cons* #\t #\\ out)))
      ((ch . rest) (loop rest
                         (cons ch out))))))

(define (config-error msg)
  (throw 'mihomo-config-error msg))

(define (source-name-char? ch)
  (or (char-alphabetic? ch)
      (char-numeric? ch)
      (char=? ch #\-)
      (char=? ch #\_)))

(define (valid-source-name? name)
  (and (> (string-length name) 0)
       (let ((first (string-ref name 0)))
         (and (or (char-alphabetic? first)
                  (char-numeric? first))
              (string-every source-name-char? name)
              (not (member name
                           '("DIRECT" "REJECT" "PROXY" "GLOBAL")))))))

(define (source-line-error line-no msg)
  (config-error (string-append "subscription manifest line "
                               (number->string line-no)
                               ": "
                               msg)))

(define (collect-source-lines raw)
  "返回 ((line-number . trimmed-line) ...)，忽略空行和 # 注释。"
  (let loop
    ((lines (string-split raw #\newline))
     (n 1)
     (out '()))
    (if (null? lines)
        (reverse out)
        (let ((line (string-trim-both (car lines))))
          (cond
            ((or (string-null? line)
                 (string-prefix? "#" line))
             (loop (cdr lines) (+ n 1) out))
            ((string-contains line "\r")
             (source-line-error n "embedded carriage return"))
            (else
             (loop (cdr lines) (+ n 1)
                   (cons (cons n line) out))))))))

(define (parse-source-entry line-no line)
  (let ((eq (string-index line #\=)))
    (unless eq
      (source-line-error line-no "expected name=value"))
    (let ((name (string-trim-both (substring line 0 eq)))
          (value (string-trim-both (substring line (+ eq 1)))))
      (unless (valid-source-name? name)
        (source-line-error line-no "invalid source name"))
      (cond
        ((or (string-prefix? "http://" value)
             (string-prefix? "https://" value))
         (when (string-any char-whitespace? value)
           (source-line-error line-no "URL contains whitespace"))
         (list name 'http value))
        ((string-prefix? "/" value)
         (when (string-null? value)
           (source-line-error line-no "empty file path"))
         (unless (string-prefix? (string-append %mihomo-data-directory "/")
                                 value)
           (source-line-error line-no
                              "file path must be under /var/lib/clash"))
         (list name 'file value))
        (else
         (source-line-error line-no
                            "value must be http(s) URL or absolute file path"))))))

(define (ensure-unique-sources sources)
  (let loop
    ((rest sources)
     (seen '()))
    (unless (null? rest)
      (let ((name (caar rest)))
        (when (member name seen)
          (config-error (string-append "duplicate source name: " name)))
        (loop (cdr rest) (cons name seen))))))

(define (parse-subscription-manifest raw)
  (when (string-contains raw (string #\nul))
    (config-error "subscription manifest contains NUL"))
  (let* ((clean (strip-one-trailing-newline raw))
         (entries (collect-source-lines clean)))
    (when (null? entries)
      (config-error "subscription manifest contains no sources"))
    (let ((sources
           (if (and (= (length entries) 1)
                    (let ((line (cdar entries)))
                      (or (string-prefix? "http://" line)
                          (string-prefix? "https://" line))))
               (let ((line (cdar entries)))
                 (when (string-any char-whitespace? line)
                   (source-line-error (caar entries)
                                      "URL contains whitespace"))
                 (list (list "airport" 'http line)))
               (map (lambda (entry)
                      (parse-source-entry (car entry) (cdr entry)))
                    entries))))
      (ensure-unique-sources sources)
      sources)))

(define (http-provider-block name url)
  (string-append
   "  " name ":\n"
   "    type: http\n"
   "    url: \"" (yaml-double-quote-escape url) "\"\n"
   "    path: \"./providers/" name ".yaml\"\n"
   "    interval: 3600\n"
   "    proxy: DIRECT\n"
   "    health-check:\n"
   "      enable: true\n"
   "      interval: 600\n"
   "      lazy: true\n"
   "      url: https://www.gstatic.com/generate_204\n"))

(define (file-provider-block name path)
  (string-append
   "  " name ":\n"
   "    type: file\n"
   "    path: \"" (yaml-double-quote-escape path) "\"\n"))

(define (provider-block sources)
  (apply string-append
         (map (lambda (source)
                (match source
                  ((name 'http url) (http-provider-block name url))
                  ((name 'file path) (file-provider-block name path))))
              sources)))

(define (source-group-block name)
  (string-append
   "  - name: SRC-" name "\n"
   "    type: select\n"
   "    use: [" name "]\n"))

(define (group-block sources)
  (let* ((names (map car sources))
         (source-groups (map source-group-block names))
         (top (string-append
               "  - name: PROXY\n"
               "    type: select\n"
               "    proxies: ["
               (string-join (map (lambda (name)
                                   (string-append "SRC-" name))
                                 names)
                            ", ")
               ", DIRECT]\n")))
    (apply string-append (append source-groups (list top)))))

(define* (compose-mihomo-config template secret-raw
                                #:optional (nm-dnsmasq-uid #f))
  "TEMPLATE（公开模板，含恰好一次 providers/groups 占位符）+
SECRET-RAW（subscription manifest）→ 完整 runtime config 文本。
可选 NM-DNSMASQ-UID（整数）启用 `tun.exclude-uid` 占位符替换。
违反契约时 (throw 'mihomo-config-error MESSAGE) fail closed；不打印、
不返回值之外地暴露 secret。"
  (let* ((template* (if nm-dnsmasq-uid
                        (begin
                          (unless (= (count-substring template
                                      %mihomo-nm-dnsmasq-uid-placeholder) 1)
                            (config-error
                             "nm-dnsmasq uid placeholder must appear exactly once"))
                          (string-replace-substring template
                           %mihomo-nm-dnsmasq-uid-placeholder
                           (number->string nm-dnsmasq-uid))) template))
         (sources (parse-subscription-manifest secret-raw)))
    (unless (= (count-substring template* %mihomo-proxy-providers-placeholder) 1)
      (config-error "proxy-providers placeholder must appear exactly once"))
    (unless (= (count-substring template* %mihomo-proxy-groups-placeholder) 1)
      (config-error "proxy-groups placeholder must appear exactly once"))
    (let* ((with-providers
            (string-replace-substring template*
             %mihomo-proxy-providers-placeholder
             (provider-block sources)))
           (with-groups
            (string-replace-substring with-providers
             %mihomo-proxy-groups-placeholder
             (group-block sources))))
      with-groups)))
