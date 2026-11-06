;;; NetworkManager dnsmasq resolver 契约测试（N1-N6）。
;;;
;;; 迁移后 DNS 所有权（docs/architecture/dns.md）：
;;;   应用 → /etc/resolv.conf 127.0.0.1:53（SmartDNS）。
;;;   fixed 模式只查 AliDNS IP DoH；dhcp 模式只查 NetworkManager
;;;   dnsmasq（127.0.0.1:15353）→ 当前 DHCP DNS。
;;;   dnsmasq 以专用稳定 UID 运行并被 `tun.exclude-uid` 排除；它是
;;;   DHCP DNS source，不是 fixed 模式的 fallback。
;;;
;;; 覆盖：
;;;   N1 NM dns backend = dnsmasq（%vm-os）
;;;   N2 dnsmasq 专用账号配置内容 + 15353 监听端口
;;;   N3 专用账号/组：显式稳定 UID/GID、system
;;;   N4 SmartDNS resolver 服务存在
;;;   N5 无 standalone dnsmasq 服务（NM 是唯一 dnsmasq owner）
;;;   N6 host 装配引用 nm-dnsmasq 配置
;;;
;;; 不依赖公网、不构建 package（纯 record/gexp/字符串断言）。
(use-modules (gnu services) ;fold-services、service-value、service-type-name
             (gnu services networking) ;network-manager-service-type 等
             (gnu system) ;operating-system-services
             (gnu system accounts) ;user-account?、user-group?
             (guixcfg hosts vm) ;%vm-os
             (guixcfg system dns nm-dnsmasq)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "nm-dnsmasq")

(test-begin "nm-dnsmasq")

(define %os-services
  (operating-system-services %vm-os))

(define (service-by-type-name name)
  (find (lambda (svc)
          (eq? name
               (service-type-name (service-kind svc)))) %os-services))

(define (repo-file-text path)
  (call-with-input-file path
    get-string-all))

(define (collapse-ws text)
  "Collapse every whitespace run in TEXT to a single space so source
wiring assertions survive formatting reflows."
  (string-join (delete ""
                       (string-split (string-map (lambda (ch)
                                                   (if (char-whitespace? ch)
                                                       #\space ch)) text)
                                     #\space)) " "))

;; ── N1：NM dns backend ──────────────────────────────────────
(define %nm-svc
  (service-by-type-name 'network-manager))

(test-assert "N1: NetworkManager service present in %vm-os"
             (and %nm-svc #t))
(test-equal "N1: NetworkManager DNS backend is dnsmasq" "dnsmasq"
            (network-manager-configuration-dns (service-value %nm-svc)))

;; ── N2：dnsmasq 专用账号配置 ────────────────────────────────
(test-assert "N2: dnsmasq conf filename is namespaced"
             (string=? %nm-dnsmasq-conf-name "00-nm-dnsmasq-user.conf"))
(test-assert "N2: dnsmasq listens on the dedicated loopback port"
             (and (= %nm-dnsmasq-port 15353)
                  (string=? %nm-dnsmasq-port-conf-name "10-listen-port.conf")
                  (string-contains %nm-dnsmasq-port-conf-content
                                   "port=15353")))

;; ── N3：专用账号/组 ─────────────────────────────────────────
(define %accounts
  (service-value (fold-services %os-services
                                #:target-type account-service-type)))

(test-assert "N3: nm-dnsmasq system group with explicit gid"
             (let ((g (find (lambda (x)
                              (and (user-group? x)
                                   (string=? %nm-dnsmasq-user
                                             (user-group-name x)))) %accounts)))
               (and g
                    (user-group-system? g)
                    (= %nm-dnsmasq-gid
                       (user-group-id g)))))
(test-assert "N3: nm-dnsmasq system account with explicit stable uid"
             (let ((u (find (lambda (x)
                              (and (user-account? x)
                                   (string=? %nm-dnsmasq-user
                                             (user-account-name x))))
                            %accounts)))
               (and u
                    (user-account-system? u)
                    (= %nm-dnsmasq-uid
                       (user-account-uid u))
                    (string=? %nm-dnsmasq-user
                              (user-account-group u)))))
(test-assert "N3: nm-dnsmasq uid is in the system range and not uid 0"
             (and (> %nm-dnsmasq-uid 0)
                  (>= %nm-dnsmasq-uid 100)
                  (<= %nm-dnsmasq-uid 999)))

;; ── N4：SmartDNS resolver 服务存在 ─────────────────────────
(test-assert "N4: SmartDNS resolver service is present"
             (and (service-by-type-name 'smartdns) #t))
;; ── N5：单一 resolver owner ─────────────────────────────────
(test-assert "N5: no standalone dnsmasq service (NM is the only owner)"
             (not (service-by-type-name 'dnsmasq)))

;; ── N6：host 装配引用 nm-dnsmasq 配置 ───────────────────────
(for-each (lambda (host-file)
            (test-assert (string-append "N6: " host-file
                          " wires dns=dnsmasq + nm-dnsmasq conf")
                         (let ((src (collapse-ws (repo-file-text host-file))))
                           (and (string-contains src "(dns \"dnsmasq\")")
                                (string-contains src
                                 "(nm-dnsmasq-dnsmasq-configuration-files)")))))
          '("modules/guixcfg/hosts/vm.scm"
            "modules/guixcfg/hosts/lenovo-legion-y7000p.scm"))


(test-end "nm-dnsmasq")
