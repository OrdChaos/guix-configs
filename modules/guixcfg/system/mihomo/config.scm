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
;;; 每个源生成一个 proxy-provider + 一个 SRC-<name> select 组；顶层
;;; PROXY select 组包含所有 SRC-* 与 DIRECT。
;;;
;;; routing-mode：
;;;   - domain：机场/普通订阅。私网直连 + Loyalsoldier proxy/direct + PROXY；
;;;   - protocol：edge 专用。UDP → UDP-HY2，TCP → TCP-REALITY；两个组
;;;     用协议源 provider + filter 选节点，规则在私网直连之后。
;;; 两种 profile 不能在同一份 rules 中按目标自动切换；由 SCM 选择。
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
            %mihomo-rules-placeholder
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

(define %mihomo-rules-placeholder
  "@@MIHOMO_RULES@@")

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

(define (provider-block sources)
  (apply string-append
         (map (lambda (source)
                (match source
                  ((name "http" url) (http-provider-block name url))
                  ((name "file" path) (file-provider-block name path))))
              sources)))

(define (source-group-block name)
  (string-append
   "  - name: SRC-" name "\n"
   "    type: select\n"
   "    use: [" name "]\n"))

(define (protocol-group-block name source filter)
  (string-append
   "  - name: " name "\n"
   "    type: select\n"
   "    use: [" source "]\n"
   "    filter: \"" (yaml-double-quote-escape filter) "\"\n"))

(define (group-block sources routing-mode protocol-source
                     protocol-udp-filter protocol-tcp-filter)
  (let* ((names (map car sources))
         (source-groups (map source-group-block names))
         (protocol-groups
          (if (eq? routing-mode 'protocol)
              (list (protocol-group-block "UDP-HY2" protocol-source
                                          protocol-udp-filter)
                    (protocol-group-block "TCP-REALITY" protocol-source
                                          protocol-tcp-filter))
              '()))
         (members
          (append
           (if (eq? routing-mode 'protocol)
               '("UDP-HY2" "TCP-REALITY")
               '())
           (map (lambda (name)
                  (string-append "SRC-" name))
                names)))
         (top (string-append
               "  - name: PROXY\n"
               "    type: select\n"
               "    proxies: ["
               (string-join (append members '("DIRECT")) ", ")
               "]\n")))
    (apply string-append
           (append source-groups protocol-groups (list top)))))

(define %mihomo-private-rules
  (string-append
   "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve\n"
   "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve\n"
   "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve\n"
   "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve\n"
   "  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve\n"
   "  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve\n"
   "  - IP-CIDR6,fc00::/7,DIRECT,no-resolve\n"
   "  - IP-CIDR6,fe80::/10,DIRECT,no-resolve\n"
   "  - IP-CIDR6,::1/128,DIRECT,no-resolve\n"))

(define (rules-block routing-mode)
  (string-append
   %mihomo-private-rules
   (if (eq? routing-mode 'protocol)
       (string-append
        "  - NETWORK,udp,UDP-HY2\n"
        "  - NETWORK,tcp,TCP-REALITY\n"
        "  - MATCH,TCP-REALITY\n")
       (string-append
        "  # proxy 在 direct 之前：两表重叠时优先走代理。\n"
        "  - RULE-SET,loyalsoldier-proxy,PROXY\n"
        "  - RULE-SET,loyalsoldier-direct,DIRECT\n"
        "  - MATCH,PROXY\n"))))

(define* (compose-mihomo-config template sources
                                #:optional (nm-dnsmasq-uid #f)
                                #:key (routing-mode 'domain)
                                      (protocol-source #f)
                                      (protocol-udp-filter "^Hysteria2$")
                                      (protocol-tcp-filter "^Reality$"))
  "TEMPLATE（公开模板，含恰好一次 providers/groups/rules 占位符）+
SOURCES（((name kind value) ...)，kind 为 \"http\"/\"file\"）→ 完整
runtime config 文本。ROUTING-MODE 为 'domain（机场/普通）或 'protocol
（UDP-HY2 / TCP-REALITY）；protocol 模式必须给出存在的 PROTOCOL-SOURCE。
可选 NM-DNSMASQ-UID（整数）启用 `tun.exclude-uid` 占位符替换。违反
契约时 (throw 'mihomo-config-error MESSAGE) fail closed；不打印、不
返回值之外地暴露源值。"
  (unless (memq routing-mode '(domain protocol))
    (config-error "routing-mode must be domain or protocol"))
  (when (and (eq? routing-mode 'protocol)
             (not protocol-source))
    (config-error "protocol routing requires protocol-source"))
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
    (when (and (eq? routing-mode 'protocol)
               (not (member protocol-source
                            (map car sources*))))
      (config-error (string-append "protocol source not declared: "
                                   protocol-source)))
    (unless (= (count-substring template* %mihomo-proxy-providers-placeholder) 1)
      (config-error "proxy-providers placeholder must appear exactly once"))
    (unless (= (count-substring template* %mihomo-proxy-groups-placeholder) 1)
      (config-error "proxy-groups placeholder must appear exactly once"))
    (unless (= (count-substring template* %mihomo-rules-placeholder) 1)
      (config-error "rules placeholder must appear exactly once"))
    (let* ((with-providers
            (string-replace-substring template*
             %mihomo-proxy-providers-placeholder
             (provider-block sources*)))
           (with-groups
            (string-replace-substring with-providers
             %mihomo-proxy-groups-placeholder
             (group-block sources* routing-mode protocol-source
                          protocol-udp-filter protocol-tcp-filter)))
           (with-rules
            (string-replace-substring with-groups
             %mihomo-rules-placeholder
             (rules-block routing-mode))))
      with-rules)))
