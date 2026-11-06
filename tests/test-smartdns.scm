;;; SmartDNS resolver / DNS mode / Mihomo decoupling contract tests（S1-S9）。
;;;
;;; 覆盖项目自有行为，不硬编码实际 DHCP DNS、订阅名、节点名或用户路径：
;;;   S1 fixed 配置仅 DoH，不含 dnsmasq 端口
;;;   S2 dhcp 配置仅 dnsmasq，不含 DoH
;;;   S3 配置共同包含 loopback bind / user / 无 fallback / 无域名列表
;;;   S4 SmartDNS 账号稳定 UID/GID
;;;   S5 mode persistence rule 投影到 /var/lib/guixcfg-dns
;;;   S6 host 装配含 SmartDNS + mode applier
;;;   S7 mode applier 是可执行 runtime（--check 实际启动）
;;;   S8 没有自定义 CLI 依赖 / activation 默认 fixed 链接
;;;   S9 模式文件是唯一 mutable 输入，applied/status 在 /run

(use-modules (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (gnu services)
             (gnu services shepherd)
             (gnu system)
             (gnu system shadow)
             (gnu system accounts)
             (guixcfg system dns smartdns)
             (guixcfg system machine-state-persistence)
             (guixcfg system persistence)
             (guixcfg hosts vm)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "smartdns")

;; ── S1/S2/S3：模式配置互斥 ─────────────────────────────────
(test-assert "S1: fixed config has no DHCP dnsmasq upstream"
             (not (string-contains %smartdns-fixed-config-content
                                   "127.0.0.1:15353")))
(test-assert "S1: fixed config uses DoH only"
             (and (string-contains %smartdns-fixed-config-content
                                   "server-https")
                  (not (string-contains %smartdns-fixed-config-content
                                        "server 127.0.0.1"))))
(test-assert "S2: dhcp config has no DoH"
             (not (string-contains %smartdns-dhcp-config-content
                                   "https://")))
(test-assert "S2: dhcp config uses dnsmasq only"
             (and (string-contains %smartdns-dhcp-config-content
                                   "server 127.0.0.1:15353")
                  (not (string-contains %smartdns-dhcp-config-content
                                        "server-https"))))
(for-each (lambda (content)
            (test-assert "S3: loopback UDP/TCP bind + smartdns user"
                         (and (string-contains content
                                               "bind 127.0.0.1:53")
                              (string-contains content
                                               "bind-tcp 127.0.0.1:53")
                              (string-contains content
                                               (string-append "user "
                                                              %smartdns-user))))
            (test-assert "S3: no fallback or domain rules"
                         (and (not (string-contains content "fallback"))
                              (not (string-contains content "domain-rules"))
                              (not (string-contains content "nameserver /")))))
          (list %smartdns-fixed-config-content
                %smartdns-dhcp-config-content))

;; ── S4：账号稳定 UID/GID ───────────────────────────────────
(define %os-services
  (operating-system-services %vm-os))

(define %accounts
  (service-value (fold-services %os-services
                                #:target-type account-service-type)))

(test-assert "S4: smartdns system group with explicit gid"
             (let ((g (find (lambda (x)
                              (and (user-group? x)
                                   (string=? %smartdns-user
                                             (user-group-name x))))
                            %accounts)))
               (and g
                    (user-group-system? g)
                    (= %smartdns-gid (user-group-id g)))))
(test-assert "S4: smartdns system account with explicit stable uid"
             (let ((u (find (lambda (x)
                              (and (user-account? x)
                                   (string=? %smartdns-user
                                             (user-account-name x))))
                            %accounts)))
               (and u
                    (user-account-system? u)
                    (= %smartdns-uid (user-account-uid u))
                    (string=? %smartdns-user (user-account-group u)))))

;; ── S5：mode persistence ───────────────────────────────────
(test-assert "S5: mode rule is valid"
             (valid-machine-state-persistence-rule?
              %smartdns-mode-persistence-rule))
(test-assert "S5: mode rule targets /var/lib/guixcfg-dns"
             (and (string=? (machine-state-persistence-rule-backing
                             %smartdns-mode-persistence-rule)
                            "guixcfg-dns")
                  (string=? (machine-state-persistence-rule-consumer
                             %smartdns-mode-persistence-rule)
                            %smartdns-state-directory)))
(test-assert "S5: mode file and applied/status are separate authorities"
             (and (string-prefix? "/var/lib/" %smartdns-mode-file)
                  (string-prefix? "/run/" %smartdns-applied-file)
                  (string-prefix? "/run/" %smartdns-status-file)))

(define %vm-activation
  (service-value (fold-services %os-services
                                #:target-type activation-service-type)))

(define (gexp-source g)
  (call-with-output-string
    (lambda (p) (write (gexp->approximate-sexp g) p))))

(test-assert "S5: host persistence includes guixcfg-dns machine state"
             (let ((p (find (lambda (projection)
                              (and (string=? "guixcfg-dns"
                                             (persistence-projection-backing
                                              projection))
                                   (string=? "/var/lib/guixcfg-dns"
                                             (persistence-projection-consumer
                                              projection))))
                            (persistence-set-projections %vm-persistence))))
               (and p
                    (string=? "/persist/system/state"
                              (persistence-projection-root p)))))
;; ── S6：service / Shepherd graph ───────────────────────────
(define (find-service type-name)
  (find (lambda (svc)
          (eq? type-name (service-type-name (service-kind svc))))
        %os-services))

(test-assert "S6: SmartDNS service present in %vm-os"
             (and (find-service 'smartdns) #t))

(define %shepherd-services
  (shepherd-configuration-services
   (service-value (fold-services %os-services
                                 #:target-type shepherd-root-service-type))))

(define (shepherd-service-with-provision name)
  (find (lambda (s)
          (memq name (shepherd-service-provision s)))
        %shepherd-services))

(test-assert "S6: smartdns daemon and mode applier are provisioned"
             (and (shepherd-service-with-provision 'smartdns)
                  (shepherd-service-with-provision 'guixcfg-dns-mode)))
(define %smartdns-svc
  (shepherd-service-with-provision 'smartdns))
(test-assert "S6: smartdns start uses foreground + config path"
             (let ((source (call-with-input-file
                               "modules/guixcfg/system/dns/smartdns.scm"
                             get-string-all)))
               (and (string-contains source "make-forkexec-constructor")
                    (string-contains source "/sbin/smartdns")
                    (string-contains source "\"-f\"")
                    (string-contains source "\"-c\"")
                    (string-contains source "%smartdns-runtime-config"))))
(test-assert "S6: mode applier does not depend on smartdns restart cycle"
             (not (memq 'smartdns
                        (shepherd-service-requirement
                         (shepherd-service-with-provision
                          'guixcfg-dns-mode)))))

;; ── S7：generated runtime 真实执行 smoke test ──────────────
(define %store
  (open-connection))

(test-assert "S7: mode applier runtime executes --check"
             (let* ((drv (run-with-store %store
                           (lower-object (smartdns-mode-program))))
                    (out (if (string? drv)
                             drv
                             (begin
                               (build-derivations %store (list drv))
                               (derivation->output-path drv)))))
               (zero? (system* out "--check"))))

;; ── S8/S9：无 CLI、默认链接、唯一 mutable 输入 ─────────────
(test-assert "S8: activation creates a default fixed config link"
             (let ((source (call-with-input-file
                               "modules/guixcfg/system/dns/smartdns.scm"
                             get-string-all)))
               (and (string-contains source "%smartdns-runtime-config")
                    (string-contains source "%smartdns-fixed-config")
                    (string-contains source "symlink"))))
(test-assert "S8: no setuid/sudo custom CLI path"
             (let ((source (call-with-input-file
                               "modules/guixcfg/system/dns/smartdns.scm"
                             get-string-all)))
               (and (not (string-contains source "setuid"))
                    (not (string-contains source "sudo")))))
(test-assert "S9: mode applier reads mode file and writes run status"
             (let ((source (call-with-input-file
                               "modules/guixcfg/system/dns/smartdns.scm"
                             get-string-all)))
               (and (string-contains source "%smartdns-mode-file")
                    (string-contains source "%smartdns-applied-file")
                    (string-contains source "%smartdns-status-file"))))

(test-end "smartdns")
