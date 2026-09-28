;;; NetworkManager dnsmasq resolver 契约测试（N1-N7）。
;;;
;;; 迁移后 DNS 所有权（docs/architecture/dns.md）：
;;;   TUN off：应用 → 系统 resolver（/etc/resolv.conf 127.0.0.1）→
;;;            NetworkManager 自带 dnsmasq → DHCP DNS。
;;;   TUN on ：mihomo fake-ip + dns-hijack；DIRECT/local 经
;;;            `direct-nameserver: system`；NetworkManager dnsmasq 以专用
;;;            稳定 UID 运行并被 `tun.exclude-uid` 排除（切断递归）。
;;;
;;; 覆盖：
;;;   N1 NM dns backend = dnsmasq（%vm-os）
;;;   N2 dnsmasq 专用账号配置内容（user=<name>）
;;;   N3 专用账号/组：显式稳定 UID/GID、system
;;;   N4 无 SmartDNS 服务残留
;;;   N5 无 standalone dnsmasq 服务（单一 resolver owner）
;;;   N6 host 装配引用 nm-dnsmasq 配置
;;;   N7 mihomo 组合配置：exclude-uid 注入同一 UID + direct-nameserver
;;;      system + fake-ip/dns-hijack
;;;
;;; 不依赖公网、不构建 package（纯 record/gexp/字符串断言）。

(use-modules (guix gexp)          ; local-file-absolute-file-name
             (gnu services)       ; fold-services、service-value、service-type-name
             (gnu services networking) ; network-manager-service-type 等
             (gnu system)         ; operating-system-services
             (gnu system accounts) ; user-account?、user-group?
             (guixcfg hosts vm)   ; %vm-os
             (guixcfg system mihomo service) ; %mihomo-template-file
             (guixcfg system mihomo config)  ; compose-mihomo-config
             (guixcfg system dns nm-dnsmasq)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "nm-dnsmasq")

(define %os-services (operating-system-services %vm-os))

(define (service-by-type-name name)
  (find (lambda (svc) (eq? name (service-type-name (service-kind svc))))
        %os-services))

(define (repo-file-text path)
  (call-with-input-file path get-string-all))

;; ── N1：NM dns backend ──────────────────────────────────────
(define %nm-svc (service-by-type-name 'network-manager))

(test-assert "N1: NetworkManager service present in %vm-os"
             (and %nm-svc #t))
(test-equal "N1: NetworkManager DNS backend is dnsmasq"
            "dnsmasq"
            (network-manager-configuration-dns (service-value %nm-svc)))

;; ── N2：dnsmasq 专用账号配置 ────────────────────────────────
(test-equal "N2: dnsmasq conf drops to the dedicated user"
            (string-append "user=" %nm-dnsmasq-user "\n")
            %nm-dnsmasq-conf-content)
(test-assert "N2: dnsmasq conf filename is namespaced"
             (string=? %nm-dnsmasq-conf-name "00-nm-dnsmasq-user.conf"))
(test-assert "N2: dnsmasq-configuration-files exposes the conf entry"
             (equal? (nm-dnsmasq-dnsmasq-configuration-files)
                     `((,%nm-dnsmasq-conf-name ,%nm-dnsmasq-conf-file))))

;; ── N3：专用账号/组 ─────────────────────────────────────────
(define %accounts
  (service-value
   (fold-services %os-services #:target-type account-service-type)))

(test-assert "N3: nm-dnsmasq system group with explicit gid"
             (let ((g (find (lambda (x)
                              (and (user-group? x)
                                   (string=? %nm-dnsmasq-user
                                             (user-group-name x))))
                            %accounts)))
               (and g
                    (user-group-system? g)
                    (= %nm-dnsmasq-gid (user-group-id g)))))
(test-assert "N3: nm-dnsmasq system account with explicit stable uid"
             (let ((u (find (lambda (x)
                              (and (user-account? x)
                                   (string=? %nm-dnsmasq-user
                                             (user-account-name x))))
                            %accounts)))
               (and u
                    (user-account-system? u)
                    (= %nm-dnsmasq-uid (user-account-uid u))
                    (string=? %nm-dnsmasq-user (user-account-group u)))))
(test-assert "N3: nm-dnsmasq uid is in the system range and not uid 0"
             (and (> %nm-dnsmasq-uid 0)
                  (>= %nm-dnsmasq-uid 100)
                  (<= %nm-dnsmasq-uid 999)))

;; ── N4：无 SmartDNS 残留 ────────────────────────────────────
(test-assert "N4: no SmartDNS service remains"
             (not (service-by-type-name 'smartdns)))

;; ── N5：单一 resolver owner ─────────────────────────────────
(test-assert "N5: no standalone dnsmasq service (NM is the only owner)"
             (not (service-by-type-name 'dnsmasq)))

;; ── N6：host 装配引用 nm-dnsmasq 配置 ───────────────────────
(for-each
 (lambda (host-file)
   (test-assert (string-append "N6: " host-file
                               " wires dns=dnsmasq + nm-dnsmasq conf")
                (let ((src (repo-file-text host-file)))
                  (and (string-contains src "(dns \"dnsmasq\")")
                       (string-contains src
                                        "(nm-dnsmasq-dnsmasq-configuration-files)")))))
 '("modules/guixcfg/hosts/vm.scm"
   "modules/guixcfg/hosts/lenovo-legion-y7000p.scm"))

;; ── N7：mihomo 组合配置与 nm-dnsmasq UID 一致 ───────────────
(define %composed
  (compose-mihomo-config
   (repo-file-text (local-file-absolute-file-name %mihomo-template-file))
   "https://subscription.invalid/path\n"
   %nm-dnsmasq-uid))

(test-assert "N7: mihomo exclude-uid injects the nm-dnsmasq UID"
             (string-contains %composed
                              (string-append "- " (number->string %nm-dnsmasq-uid))))
(test-assert "N7: mihomo direct-nameserver uses the system resolver"
             (string-contains %composed "direct-nameserver:\n    - system"))
(test-assert "N7: fake-ip + dns-hijack present"
             (and (string-contains %composed "enhanced-mode: fake-ip")
                  (string-contains %composed "- any:53")
                  (string-contains %composed "tcp://any:53")))
(test-assert "N7: no unresolved placeholders remain"
             (and (not (string-contains %composed "@@MIHOMO_SUBSCRIPTION_URL@@"))
                  (not (string-contains %composed "@@MIHOMO_NM_DNSMASQ_UID@@"))))

(test-end "nm-dnsmasq")
