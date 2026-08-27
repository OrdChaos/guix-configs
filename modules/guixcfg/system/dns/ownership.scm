;;; System DNS ownership（Phase 2，docs/architecture/dns.md）。
;;;
;;; 最终链：Applications → /etc/resolv.conf（静态 127.0.0.1）→
;;; SmartDNS → 固定 upstream。本模块拥有 /etc 层的两个声明式文件：
;;;
;;;   1. /etc/resolv.conf（静态，repo authority）：
;;;      "nameserver 127.0.0.1"——SmartDNS 是唯一 system resolver；
;;;      NetworkManager 不再写它（libc subscriber 被重定向，见 2）。
;;;      glibc 对 AAAA 同样经此 nameserver 查询，无需 ::1 条目。
;;;
;;;   2. /etc/resolvconf.conf（openresolv 重定向，repo authority）：
;;;      resolv_conf=/run/resolvconf/resolv.conf——NM 的 DHCP DNS
;;;      仍然经 resolvconf -a 记录，但 libc subscriber 只写 /run 的
;;;      upstream metadata（本模块导出的 %dhcp-dns-metadata-path，
;;;      v1 只产出、SmartDNS 暂不消费——未来 DHCP-DNS-as-upstream
;;;      的 seam）。其余 subscriber（named/dnsmasq/unbound 等）显式
;;;      关闭：openresolv 3.17.4 的 -u 会运行 LIBEXECDIR 下全部
;;;      subscriber（store 实测 sbin/resolvconf:1488 的 for 循环），
;;;      无对应 daemon 的 subscriber 会留下杂项行为——按
;;;      <name>_enabled=NO 逐一禁用，只留 libc。
;;;
;;; 不变量（docs/architecture/dns.md）：
;;;   - /etc/resolv.conf 只有一个 owner（本模块；NM/openresolv 均不
;;;     触碰——libc subscriber 的输出路径已重定向）；
;;;   - DHCP DNS 不丢弃：作为 /run metadata 保留（v1 不消费）；
;;;   - 不依赖 systemd-resolved、不引入 firewall。

(define-module (guixcfg system dns ownership)
               #:use-module (gnu services)      ; simple-service
               #:use-module (gnu services base) ; etc-service-type
               #:use-module (guix gexp)         ; plain-file、local-file
               #:export (%system-resolv-conf
                         %resolvconf-config
                         %dhcp-dns-metadata-path
                         system-dns-etc-service))

(define %dhcp-dns-metadata-path "/run/resolvconf/resolv.conf")

(define %system-resolv-conf
  ;; SmartDNS 是唯一 system resolver。IPv6 AAAA 查询同样经此
  ;; nameserver（SmartDNS 向上游问 AAAA）——不需要 ::1 条目。
  (plain-file "resolv.conf" "nameserver 127.0.0.1\n"))

(define %resolvconf-config
  ;; colocate 独立文件（dns/resolvconf.conf；注释见该文件头）。
  (local-file "resolvconf.conf" "resolvconf.conf"))

(define (system-dns-etc-service)
  "声明式物化 /etc/resolv.conf 与 /etc/resolvconf.conf（ephemeral
root 每 boot 重建；唯一 owner = 本模块）。"
  (simple-service 'system-dns-files etc-service-type
                  `(("resolv.conf" ,%system-resolv-conf)
                    ("resolvconf.conf" ,%resolvconf-config))))
