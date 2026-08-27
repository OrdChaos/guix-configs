;;; SmartDNS system service（Phase 2 v1，docs/architecture/dns.md）。
;;;
;;; 自建 thin service（同 mihomo 模式），复用 Guix 官方 smartdns
;;; package（pin 47，gnu/packages/dns.scm）。不复用 Rosenthal
;;; smartdns-service-type 的原因：其 shepherd 无 #:log-file（-f 的
;;; 日志被丢弃，排障不可用）、provision 含 'dns（本仓库无消费者），
;;; 且 config 无扩展面——本模块只多 ~40 行、语义全部本仓库所有。
;;;
;;; v1 边界（不引入分流/过滤/测速/ECS/DoH bootstrap）：
;;;   - 只监听 loopback（127.0.0.1:53 与 [::1]:53，UDP+TCP）——
;;;     smartdns 默认 bind [::]:53 监听所有接口，必须显式收紧；
;;;   - 固定 IP literal upstream（无 hostname bootstrap；mihomo 侧
;;;     加对应 DIRECT 规则保证不绕经节点——见 mihomo-template.yaml）；
;;;   - cache 仅内存（cache-persist no；丢失代价=首查稍慢）；
;;;   - DHCP DNS 不消费：openresolv 已把 NM 的 DHCP nameserver 产出
;;;     为 /run/resolvconf/resolv.conf metadata（(guixcfg system dns)
;;;     的 %dhcp-dns-metadata-path）——未来 seam，v1 不读。
;;;
;;; failure semantics（VM 实测 smartdns 47）：
;;;   - upstream 不可达：daemon 正常运行、查询 SERVFAIL（~2s 超时）、
;;;     网络恢复后自动恢复（per-query 重试，无 failure latch）；
;;;   - crash：/etc/resolv.conf 仍指 127.0.0.1 → DNS unavailable =
;;;     fail-closed（不做自动回退 DHCP DNS）；respawn 默认开；
;;;   - SIGHUP = monitor 重启 child 重读 config（官方语义）。

(define-module (guixcfg system dns smartdns)
               #:use-module (gnu services)          ; service、service-type、service-extension
               #:use-module (gnu services shepherd) ; shepherd-service
               #:use-module (gnu packages dns)      ; smartdns
               #:use-module (guix gexp)
               #:export (%smartdns-config-file
                         %smartdns-log-file
                         smartdns-shepherd-service
                         smartdns-service-type
                         smartdns-service))

(define %smartdns-log-file "/var/log/smartdns.log")

;; v1 最小配置（公开、无 secret）。上游为固定 IP literal；不启用
;; cache-persist（无持久化需求）；不做测速/分流。
(define %smartdns-config-file
  ;; colocate 独立文件（dns/smartdns.conf；注释见该文件头）。
  (local-file "smartdns.conf" "smartdns.conf"))

(define (smartdns-shepherd-service)
  (list (shepherd-service
         (provision '(smartdns))
         (requirement '(loopback networking))
         (documentation
          "Run SmartDNS as the system resolver (loopback only; fixed \
upstreams; DHCP DNS is recorded as /run metadata by openresolv, not \
consumed in Phase 2 v1).")
         (start #~(make-forkexec-constructor
                   (list #$(file-append smartdns "/sbin/smartdns")
                         "-f" "-c" #$%smartdns-config-file)
                   #:log-file #$%smartdns-log-file))
         (stop #~(make-kill-destructor)))))

(define smartdns-service-type
  (service-type
   (name 'smartdns)
   (extensions
    (list (service-extension shepherd-root-service-type
                             (lambda (config) (smartdns-shepherd-service)))))
   (default-value #t)
   (description
    "Run SmartDNS as the sole system resolver: loopback-only listener \
with fixed explicit upstreams.")))

(define (smartdns-service)
  (service smartdns-service-type #t))
