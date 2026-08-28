;;; SmartDNS / system DNS ownership 单元测试（S1-S7，Phase 2 v1）。
;;;
;;; 覆盖：
;;;   S1 smartdns 配置静态契约（loopback-only、无 cache-persist、
;;;      固定 upstream、无测速/分流）
;;;   S2 /etc/resolv.conf 静态 ownership（恰好 nameserver 127.0.0.1）
;;;   S3 resolvconf.conf 重定向 /run + 非 libc subscriber 全关
;;;   S4 service graph：smartdns provision/requirement
;;;   S5 resolvconf-bootstrap 退役（服务与 NM requirement 均不存在）
;;;   S6 mihomo rules 不含 SmartDNS upstream DIRECT（上游查询走代理，
;;;      宿主侧 fake-ip DNS 劫持明文 53）
;;;   S7 store 无 secret/无网络依赖（配置纯公开文本）

(use-modules (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (gnu services)
             (gnu services shepherd)
             (gnu services networking) ; network-manager-configuration-shepherd-requirement
             (gnu system)              ; operating-system-services
             (guixcfg system dns ownership)
             (guixcfg system dns smartdns)
             (guixcfg system mihomo service) ; %mihomo-template-file（rules 一致性）
             (guixcfg hosts vm)        ; %os
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %store (open-connection))

(define (file-text file-like)
  "lower FILE-LIKE 并读取其 store 内容（同 test-mihomo 模式）。"
  (let ((out (run-with-store %store (lower-object file-like))))
    (call-with-input-file
     (if (string? out)
       out
       (begin
         (build-derivations %store (list out))
         (derivation->output-path out)))
     get-string-all)))

(define %smartdns-text (file-text %smartdns-config-file))
(define %resolv-conf-text (file-text %system-resolv-conf))
(define %resolvconf-conf-text (file-text %resolvconf-config))
(define %mihomo-template-text
  (file-text %mihomo-template-file))

(define (shepherd-service-with-provision name)
  (find (lambda (s)
          (memq name (shepherd-service-provision s)))
        (shepherd-configuration-services
         (service-value
          (fold-services (operating-system-services %os)
                         #:target-type shepherd-root-service-type)))))

(test-begin "smartdns")

;; ── S1：smartdns 配置契约 ──────────────────────────────────
(test-assert "S1: loopback-only binds (UDP+TCP, v4 only)"
             (and (string-contains %smartdns-text "bind 127.0.0.1:53")
                  (string-contains %smartdns-text "bind-tcp 127.0.0.1:53")
                  ;; 不绑 [::1]：resolver 是 v4-literal，[::1] 无消费者；
                  ;; 绑定会使 DNS 服务在 IPv6 被禁用时启动失败
                  ;; （2026-08-28 VM 实测）。
                  (not (string-contains %smartdns-text "bind [::1]:53"))
                  (not (string-contains %smartdns-text "bind-tcp [::1]:53"))))
(test-assert "S1: never binds wildcard interfaces"
             (not (string-contains %smartdns-text "bind [::]:53")))
(test-assert "S1: no cache-persist (memory cache only)"
             (not (string-contains %smartdns-text "cache-persist")))
(test-assert "S1: fixed upstreams declared"
             (and (string-contains %smartdns-text "server 223.5.5.5")
                  (string-contains %smartdns-text "server 119.29.29.29")))
(test-assert "S1: no speed-check / no domain routing in v1"
             (and (not (string-contains %smartdns-text "speed-check-mode"))
                  (not (string-contains %smartdns-text "nameserver /"))))

;; ── S2：/etc/resolv.conf 静态 ownership ────────────────────
(test-equal "S2: resolv.conf is exactly the localhost resolver"
            "nameserver 127.0.0.1\n"
            %resolv-conf-text)

;; ── S3：resolvconf.conf 重定向 /run ────────────────────────
(test-assert "S3: libc subscriber redirected to /run metadata path"
             (string-contains %resolvconf-conf-text
                              (string-append "resolv_conf="
                                             %dhcp-dns-metadata-path)))
(test-assert "S3: non-libc subscribers explicitly disabled"
             (and (string-contains %resolvconf-conf-text "dnsmasq_enabled=NO")
                  (string-contains %resolvconf-conf-text "named_enabled=NO")
                  (string-contains %resolvconf-conf-text "unbound_enabled=NO")
                  (string-contains %resolvconf-conf-text
                                   "systemd_resolved_enabled=NO")))
(test-assert "S3: metadata path lives under /run"
             (string-prefix? "/run/" %dhcp-dns-metadata-path))

;; ── S4：service graph ──────────────────────────────────────
(define %smartdns-svc (shepherd-service-with-provision 'smartdns))
(test-assert "S4: smartdns service present with loopback+networking"
             (and %smartdns-svc
                  (memq 'loopback (shepherd-service-requirement %smartdns-svc))
                  (memq 'networking (shepherd-service-requirement %smartdns-svc))))
(test-assert "S4: smartdns start runs foreground with config and log-file"
             ;; file-like ungexp 在 approximate-sexp 里是 (*approximate*)
             ;; 占位（store 路径要 lower 才有）——只断言字面量与 log-file。
             (let ((sexp (object->string
                          (gexp->approximate-sexp
                           (shepherd-service-start %smartdns-svc)))))
               (and (string-contains sexp "-f")
                    (string-contains sexp "-c")
                    (string-contains sexp "/var/log/smartdns.log"))))

;; ── S5：resolvconf-bootstrap 退役 ──────────────────────────
(test-assert "S5: resolvconf-bootstrap service gone"
             (not (shepherd-service-with-provision 'resolvconf-bootstrap)))
(test-assert "S5: NM no longer requires resolvconf-bootstrap"
             (let* ((nm (find (lambda (svc)
                                (eq? 'network-manager
                                     (service-type-name (service-kind svc))))
                              (operating-system-services %os)))
                    (req (network-manager-configuration-shepherd-requirement
                          (service-value nm))))
               (not (memq 'resolvconf-bootstrap req))))

;; ── S6：mihomo rules 与 smartdns upstream 一致 ─────────────
;; 上游查询必须走代理（MATCH→PROXY）：宿主侧 fake-ip DNS 劫持明文
;; 53 端口，DIRECT 规则会永远拿到假 IP（2026-08-28 VM 实测）。
(test-assert "S6: no DIRECT rules for smartdns upstreams (must ride the proxy)"
             (and (not (string-contains %mihomo-template-text
                                        "223.5.5.5/32,DIRECT"))
                  (not (string-contains %mihomo-template-text
                                        "119.29.29.29/32,DIRECT"))))

;; ── S7：配置公开、无 store secret 面 ───────────────────────
(test-assert "S7: no URL/secret-like content in public DNS configs"
             (let ((all (string-append %smartdns-text
                                       %resolv-conf-text
                                       %resolvconf-conf-text)))
               (not (string-contains all "://"))))

(test-end "smartdns")
