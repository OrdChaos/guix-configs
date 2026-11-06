;;; Mihomo system service 测试：只保留模板静态契约与 service graph。
;;;
;;; 订阅源建模、provider/group 组合的行为不在这里写
;;; 字符串断言——那些由实际 mihomo -t / build 验证，避免把订阅名、
;;; 节点名、用户路径写死在测试里。

(use-modules (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (gnu services)
             (gnu services shepherd)
             (gnu system) ;operating-system-services
             (gnu system shadow) ;user-group?
             (guixcfg system mihomo service)
             (guixcfg system mihomo config)
             (guixcfg system dns nm-dnsmasq)
             (guixcfg system dns smartdns)
             (guixcfg system machine-state-persistence) ;rule 校验
             (guixcfg hosts vm) ;%vm-os
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))


(define %store
  (open-connection))

(define (template-text)
  "公开模板的 store 内容（local-file lower；与 test-niri-config
同一模式）。"
  (let ((out (run-with-store %store
                             (lower-object %mihomo-template-file))))
    (call-with-input-file (if (string? out) out
                              (begin
                                (build-derivations %store
                                                   (list out))
                                (derivation->output-path out)))
      get-string-all)))

(test-begin "mihomo")

;; ── M7：模板静态契约 ────────────────────────────────────────
(test-assert "M7: provider/group and both resolver UID placeholders appear once"
             (let ((text (template-text)))
               (and (= (count-substring text
                                        %mihomo-proxy-providers-placeholder) 1)
                    (= (count-substring text
                                        %mihomo-proxy-groups-placeholder) 1)
                    (= (count-substring text
                                        %mihomo-nm-dnsmasq-uid-placeholder) 1)
                    (= (count-substring text
                                        %mihomo-smartdns-uid-placeholder) 1))))
(test-assert "M7: no source URL or legacy placeholder in public template"
             (let ((text (template-text)))
               (and (not (string-contains text "@@MIHOMO_SUBSCRIPTION_URL@@"))
                    (not (string-contains text "token=")))))
(test-assert "M7: mihomo no longer owns or hijacks DNS"
             (let ((text (template-text)))
               (and (not (string-contains text "\ndns:"))
                    (not (string-contains text "listen: \"127.0.0.1:53\""))
                    (not (string-contains text "dns-hijack:"))
                    (not (string-contains text "enhanced-mode: redir-host"))
                    (not (string-contains text "enhanced-mode: fake-ip"))
                    (not (string-contains text "fallback:"))
                    (not (string-contains text "fallback-filter:"))
                    (not (string-contains text "proxy-server-nameserver:")))))
(test-assert "M7: tun exclude-uid references both resolver UIDs"
             (let ((text (template-text)))
               (and (string-contains text "exclude-uid:")
                    (string-contains text
                                     (string-append "- "
                                      %mihomo-nm-dnsmasq-uid-placeholder))
                    (string-contains text
                                     (string-append "- "
                                      %mihomo-smartdns-uid-placeholder)))))
(test-assert "M7: compose replaces both resolver UID placeholders"
             (let ((config (compose-mihomo-config
                            (template-text)
                            '(("fixture" "file"
                               "/var/lib/clash/fixture.yaml"))
                            %nm-dnsmasq-uid
                            %smartdns-uid)))
               (and (not (string-contains config
                                          %mihomo-nm-dnsmasq-uid-placeholder))
                    (not (string-contains config
                                          %mihomo-smartdns-uid-placeholder))
                    (string-contains config
                                     (string-append "- "
                                                    (number->string
                                                     %nm-dnsmasq-uid)))
                    (string-contains config
                                     (string-append "- "
                                                    (number->string
                                                     %smartdns-uid))))))
;; ── M8：controller 仅 loopback ──────────────────────────────
(test-assert "M8: external-controller is loopback-only"
             (and (string-contains (template-text)
                                   "external-controller: 127.0.0.1:9090")
                  (not (string-contains (template-text)
                                        "external-controller: 0.0.0.0"))))
(test-assert "M8: controller secret explicitly empty"
             (string-contains (template-text) "secret: \"\""))

;; ── M11：service graph ──────────────────────────────────────
(define %mihomo-service-instance
  (find (lambda (svc)
          (eq? 'mihomo
               (service-type-name (service-kind svc))))
        (operating-system-services %vm-os)))

(test-assert "M11: mihomo service present in %vm-os"
             (and %mihomo-service-instance #t))

(define (shepherd-service-with-provision name)
  (find (lambda (s)
          (memq name
                (shepherd-service-provision s)))
        (shepherd-configuration-services (service-value (fold-services (operating-system-services
                                                                        %vm-os)
                                                         #:target-type
                                                         shepherd-root-service-type)))))

(define %mihomo-daemon
  (shepherd-service-with-provision 'mihomo))
(define %mihomo-config-svc
  (shepherd-service-with-provision 'mihomo-config-ready))

(test-assert
 "M11: mihomo daemon requires config-ready + networking (no smartdns)"
 (let ((req (shepherd-service-requirement %mihomo-daemon)))
   (and (memq 'mihomo-config-ready req)
        (memq 'networking req)
        (memq 'loopback req)
        ;; DNS is owned by mihomo itself (loopback :53, AliDNS + DHCP
        ;; fallback) and by NetworkManager dnsmasq (:15353); the old
        ;; SmartDNS requirement is gone.
        (not (memq 'smartdns req)))))
(test-assert "M11: materializer requires ordinary-secrets-ready"
             (memq 'ordinary-secrets-ready
                   (shepherd-service-requirement %mihomo-config-svc)))
(test-assert "M11: materializer is one-shot"
             (shepherd-service-one-shot? %mihomo-config-svc))
(test-assert "M11: daemon start uses -d data dir and -f runtime config"
             (let ((sexp (object->string (gexp->approximate-sexp (shepherd-service-start
                                                                  %mihomo-daemon)))))
               (and (string-contains sexp "/var/lib/clash")
                    (string-contains sexp "-f")
                    (string-contains sexp "/run/mihomo/config.yaml"))))

;; ── M12：account / machine-state rule ───────────────────────
(test-assert "M12: clash system group in folded accounts"
             (let ((accounts (service-value (fold-services (operating-system-services
                                                            %vm-os)
                                             #:target-type
                                             account-service-type))))
               (and (find (lambda (g)
                            (and (user-group? g)
                                 (string=? "clash"
                                           (user-group-name g))
                                 (user-group-system? g))) accounts) #t)))
(test-assert "M12: data dir machine-state rule is valid"
             (valid-machine-state-persistence-rule?
              %mihomo-data-persistence-rule))
(test-assert "M12: data rule targets the whole /var/lib/clash data dir"
             (and (string=? (machine-state-persistence-rule-backing
                             %mihomo-data-persistence-rule) "mihomo/clash")
                  (string=? (machine-state-persistence-rule-consumer
                             %mihomo-data-persistence-rule) "/var/lib/clash")))
(test-assert
 "M12: activation chmods the rule backing (no providers-only drift)"
 ;; Regression: activation used to chmod a stale
 ;; /persist/.../mihomo/providers path, leaving the real
 ;; mihomo/clash backing at generic 0755.
 (let ((source (call-with-input-file "modules/guixcfg/system/mihomo/service.scm"
                 get-string-all)))
   (and (string-contains source "machine-state-persistence-rule-backing")
        (not (string-contains source "\"/mihomo/providers\"")))))


(test-end "mihomo")
