;;; Mihomo runtime config composition（纯逻辑，无 gnu/guix imports）：
;;; 公开模板 + 已解密的源值列表 → 完整 runtime config 文本。
;;;
;;; 与 (guixcfg system mihomo service) 分离的原因：materializer program-file
;;; 经 source-module-closure 导入本模块（#:select?
;;; guixcfg-module-select?）——保持闭包最小（srfi/match only），
;;; 避免把 gnu/services 依赖拖进 generated runtime（AGENT.md §3
;;; 符号审计面）。
;;;
;;; 输入 sources：((name kind value) ...)，kind 为 "http" 或 "file"，
;;; value 是 service materializer 从该源 age 文件读出的明文：
;;;   - http → 一个 http(s) URL；
;;;   - file → materializer 从 age 内容生成的 /var/lib/clash 路径
;;;     （compose 本身不解析 provider YAML）。
;;; 每个源生成一个 proxy-provider + 一个 <name> select 组；顶层
;;; PROXY select 组包含所有 <name> 子组与 DIRECT。
;;;
;;; 运行时路径契约（single-owner constants）：
;;;   - secret 路径/target 名由 (guixcfg system mihomo sources) 声明，
;;;     service 侧用 runtime-secret-target 派生后传给 materializer；
;;;   - 文件源路径必须在 -d（/var/lib/clash）下，否则 mihomo 的
;;;     SAFE_PATHS 检查会拒绝。

(define-module (guixcfg system mihomo config)
  #:use-module (srfi srfi-13) ;string-*、string-join
  #:use-module (ice-9 string-fun) ;string-replace-substring
  #:use-module (ice-9 match)
  #:export (%mihomo-proxy-providers-placeholder
            %mihomo-proxy-groups-placeholder
            %mihomo-nm-dnsmasq-uid-placeholder
            %mihomo-runtime-dir
            %mihomo-runtime-config-path
            %mihomo-data-directory
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

(define %mihomo-runtime-dir
  "/run/mihomo")

(define %mihomo-runtime-config-path
  "/run/mihomo/config.yaml")

;; mihomo 的 -d 数据目录；file provider 的 path 必须在它下面（mihomo
;; 的 SAFE_PATHS 检查），否则运行时会拒绝加载。
(define %mihomo-data-directory
  "/var/lib/clash")

;; 文件源 materializer 写出的 provider 目录；路径必须在 -d 下。
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

(define (validate-source-value name kind raw)
  (let ((value (strip-one-trailing-newline raw)))
    (when (string-contains value (string #\nul))
      (config-error (string-append "source " name " value contains NUL")))
    (when (or (string-contains value "\r")
              (string-contains value "\n"))
      (config-error (string-append "source " name
                                   " value contains CR/LF")))
    (cond
      ((string=? kind "http")
       (unless (or (string-prefix? "http://" value)
                   (string-prefix? "https://" value))
         (config-error (string-append "source " name
                                      " is not an http(s) URL")))
       (when (string-any char-whitespace? value)
         (config-error (string-append "source " name
                                      " URL contains whitespace")))
       value)
      ((string=? kind "file")
       (unless (string-prefix? (string-append %mihomo-data-directory "/")
                               value)
         (config-error (string-append "source " name
                                      " file path must be under /var/lib/clash")))
       value)
      (else
       (config-error (string-append "source " name
                                    " has invalid kind: " kind))))))

(define (normalize-sources sources)
  (when (null? sources)
    (config-error "at least one subscription source is required"))
  (let loop
    ((rest sources)
     (names '())
     (out '()))
    (if (null? rest)
        (reverse out)
        (match (car rest)
          ((name kind raw)
           (unless (valid-source-name? name)
             (config-error "invalid subscription source name"))
           (when (member name names)
             (config-error (string-append "duplicate source name: " name)))
           (let ((value (validate-source-value name kind raw)))
             (loop (cdr rest)
                   (cons name names)
                   (cons (list name kind value) out))))
          (_ (config-error "malformed subscription source record"))))))

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

(define (provider-id name)
  "Provider name 与策略组名分开：组用用户可见的 <name>，provider 用
provider-<name>，避免同名组被 provider 遮蔽。"
  (string-append "provider-" name))

(define (provider-block sources)
  (apply string-append
         (map (lambda (source)
                (match source
                  ((name "http" url)
                   (http-provider-block (provider-id name) url))
                  ((name "file" path)
                   (file-provider-block (provider-id name) path))))
              sources)))

(define (source-group-block name)
  (string-append
   "  - name: " name "\n"
   "    type: select\n"
   "    use: [" (provider-id name) "]\n"))

(define (group-block sources)
  (let* ((names (map car sources))
         (source-groups (map source-group-block names))
         (top (string-append
               "  - name: PROXY\n"
               "    type: select\n"
               "    proxies: ["
               (string-join names ", ")
               ", DIRECT]\n")))
    (apply string-append (append source-groups (list top)))))

(define* (compose-mihomo-config template sources
                                #:optional (nm-dnsmasq-uid #f))
  "TEMPLATE（公开模板，含恰好一次 providers/groups 占位符）+
SOURCES（((name kind value) ...)，kind 为 \"http\"/\"file\"）→ 完整
runtime config 文本。可选 NM-DNSMASQ-UID（整数）启用 `tun.exclude-uid`
占位符替换。违反契约时 (throw 'mihomo-config-error MESSAGE) fail closed；
不打印、不返回值之外地暴露源值。"
  (let* ((template* (if nm-dnsmasq-uid
                        (begin
                          (unless (= (count-substring template
                                      %mihomo-nm-dnsmasq-uid-placeholder) 1)
                            (config-error
                             "nm-dnsmasq uid placeholder must appear exactly once"))
                          (string-replace-substring template
                           %mihomo-nm-dnsmasq-uid-placeholder
                           (number->string nm-dnsmasq-uid))) template))
         (sources* (normalize-sources sources)))
    (unless (= (count-substring template* %mihomo-proxy-providers-placeholder) 1)
      (config-error "proxy-providers placeholder must appear exactly once"))
    (unless (= (count-substring template* %mihomo-proxy-groups-placeholder) 1)
      (config-error "proxy-groups placeholder must appear exactly once"))
    (let* ((with-providers
            (string-replace-substring template*
             %mihomo-proxy-providers-placeholder
             (provider-block sources*)))
           (with-groups
            (string-replace-substring with-providers
             %mihomo-proxy-groups-placeholder
             (group-block sources*))))
      with-groups)))
