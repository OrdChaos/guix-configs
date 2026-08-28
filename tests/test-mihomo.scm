;;; Mihomo system service 单元测试（M1-M12）。
;;;
;;; 覆盖：
;;;   M1-M6  config composition 纯逻辑（占位符、尾换行、CR/LF/NUL
;;;          fail closed、YAML 双引号转义）
;;;   M7-M10 公开模板静态契约（占位符唯一、Phase 1 边界、controller
;;;          loopback、无 secret 泄漏面）
;;;   M11-M12 service graph（shepherd requirement/provision、
;;;          account group、machine-state rule）
;;;
;;; materializer 的真实执行 smoke test 在 tests/test-runtime-exec.scm
;;; （MC1-MC3，fake root + user namespace + chroot 模式）。
;;; 测试不依赖公网、不构建 Mihomo package（纯 record/gexp 断言）。

(use-modules (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (gnu services)
             (gnu services shepherd)
             (gnu system)          ; operating-system-services
             (gnu system shadow)   ; user-group?
             (guixcfg system mihomo service)
             (guixcfg system mihomo config)
             (guixcfg system machine-state-persistence) ; rule 校验
             (guixcfg security secrets) ; secret-decl-name（M13）
             (guixcfg hosts vm)   ; %os
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %store (open-connection))

(define (template-text)
  "公开模板的 store 内容（local-file lower；与 test-niri-config
同一模式）。"
  (let ((out (run-with-store %store (lower-object %mihomo-template-file))))
    (call-with-input-file
     (if (string? out)
       out
       (begin
         (build-derivations %store (list out))
         (derivation->output-path out)))
     get-string-all)))

;; 最小模板片段（纯逻辑测试用；占位符恰好一次）。
(define %mini-template
  "proxy-providers:\n  airport:\n    url: \"@@MIHOMO_SUBSCRIPTION_URL@@\"\n")

(define (caught-error thunk)
  "THUNK 抛 'mihomo-config-error 时返回其消息，否则 #f。"
  (catch 'mihomo-config-error
    (lambda () (thunk) #f)
    (lambda (key msg) msg)))

(test-begin "mihomo")

;; ── M1：尾换行剥离（LF 与 CRLF 各一）────────────────────────
(test-assert "M1: trailing LF stripped"
             (string-contains (compose-mihomo-config
                               %mini-template "https://a.invalid/x\n")
                              "url: \"https://a.invalid/x\""))
(test-assert "M1: trailing CRLF stripped"
             (string-contains (compose-mihomo-config
                               %mini-template "https://a.invalid/x\r\n")
                              "url: \"https://a.invalid/x\""))

;; ── M2：剥离后残留 CR/LF/NUL → fail closed ──────────────────
(test-assert "M2: CR after strip fails closed"
             (caught-error
              (lambda () (compose-mihomo-config %mini-template
                                                "https://a.invalid\rb"))))
(test-assert "M2: double newline (only one strip) fails closed"
             (caught-error
              (lambda () (compose-mihomo-config %mini-template
                                                "https://a.invalid/b\n\n"))))
(test-assert "M2: NUL after strip fails closed"
             (caught-error
              (lambda () (compose-mihomo-config
                          %mini-template
                          (string-append "https://a.invalid"
                                         (string #\nul) "b\n")))))

;; ── M3：占位符恰好一次 ──────────────────────────────────────
(test-assert "M3: missing placeholder fails closed"
             (caught-error
              (lambda () (compose-mihomo-config "no placeholder here\n"
                                                "https://a.invalid\n"))))
(test-assert "M3: duplicated placeholder fails closed"
             (caught-error
              (lambda ()
                (compose-mihomo-config
                 (string-append %mini-template
                                "    x: \"@@MIHOMO_SUBSCRIPTION_URL@@\"\n")
                 "https://a.invalid\n"))))
(test-assert "M3: exact placeholder succeeds"
             (string-contains (compose-mihomo-config %mini-template
                                                     "https://a.invalid\n")
                              "https://a.invalid"))

;; ── M4：YAML 双引号转义 ─────────────────────────────────────
(test-assert "M4: double quote escaped"
             (string-contains (compose-mihomo-config
                               %mini-template "https://a.invalid/?q=\"x\"\n")
                              "q=\\\"x\\\""))
(test-assert "M4: backslash escaped"
             (string-contains (compose-mihomo-config
                               %mini-template "https://a.invalid/a\\b\n")
                              "a\\\\b"))

;; ── M5：count-substring ─────────────────────────────────────
(test-assert "M5: count-substring"
             (and (= (count-substring "aaXbbX" "X") 2)
                  (= (count-substring "aaa" "aa") 1)
                  (= (count-substring "abc" "z") 0)))

;; ── M6：compose 不打印 secret（输出只含模板+替换）───────────
(test-assert "M6: no secret in composition error messages"
             (not (string-contains (or (caught-error
                                        (lambda () (compose-mihomo-config
                                                    "x\n" "SECRET_URL\n")))
                                       "")
                                   "SECRET_URL")))

;; ── M7：模板静态契约 ────────────────────────────────────────
(test-assert "M7: placeholder appears exactly once in template"
             (= (count-substring (template-text)
                                 %mihomo-subscription-placeholder) 1))
(test-assert "M7: no subscription URL in public template"
             ;; 模板中唯一的 "://" 是健康检查 URL（gstatic 公开常量）；
             ;; 订阅 URL 行只有占位符。
             (and (= (count-substring (template-text) "://") 1)
                  (string-contains (template-text)
                                   "https://www.gstatic.com/generate_204")
                  (string-contains (template-text)
                                   "url: \"@@MIHOMO_SUBSCRIPTION_URL@@\"")))
(test-assert "M7: dns-hijack explicitly empty"
             (string-contains (template-text) "dns-hijack: []"))
(test-assert "M7: no fake-ip key"
             (not (string-contains (template-text) "fake-ip:")))
(test-assert "M7: no default DNS hijack target"
             (not (string-contains (template-text) "0.0.0.0:53")))

;; ── M8：controller 仅 loopback ──────────────────────────────
(test-assert "M8: external-controller is loopback-only"
             (and (string-contains (template-text)
                                   "external-controller: 127.0.0.1:9090")
                  (not (string-contains (template-text)
                                        "external-controller: 0.0.0.0"))))
(test-assert "M8: controller secret explicitly empty"
             (string-contains (template-text) "secret: \"\""))

;; ── M9：provider 原生 http + DIRECT 订阅刷新 ─────────────────
(test-assert "M9: provider is native http type"
             (string-contains (template-text) "type: http"))
;; proxy: DIRECT——订阅刷新不依赖代理组/节点可用性（节点全挂时刷新
;; 照常；直连可行性：节点域名解析经 SmartDNS 直连上游自举 +
;; 宿主直连出站可信，2026-08-28 VM 实测直连拉取成功）。
(test-assert "M9: provider refresh dials DIRECT"
             (string-contains (template-text) "proxy: DIRECT"))
(test-assert "M9: provider interval declared"
             (string-contains (template-text) "interval: 3600"))
(test-assert "M9: provider path under data directory"
             (string-contains (template-text)
                              "path: ./providers/airport.yaml"))

;; ── M10：TUN 契约 ───────────────────────────────────────────
(test-assert "M10: tun enabled with mixed stack"
             (and (string-contains (template-text) "enable: true")
                  (string-contains (template-text) "stack: mixed")))
(test-assert "M10: auto-route / auto-redirect / auto-detect-interface"
             (and (string-contains (template-text) "auto-route: true")
                  (string-contains (template-text) "auto-redirect: true")
                  (string-contains (template-text)
                                   "auto-detect-interface: true")))
(test-assert "M10: ipv6 disabled (v4-only airport nodes cannot reach v6)"
             (string-contains (template-text) "ipv6: false"))

;; ── M11：service graph ──────────────────────────────────────
(define %mihomo-service-instance
  (find (lambda (svc)
          (eq? 'mihomo (service-type-name (service-kind svc))))
        (operating-system-services %os)))

(test-assert "M11: mihomo service present in %os"
             (and %mihomo-service-instance #t))

(define (shepherd-service-with-provision name)
  (find (lambda (s)
          (memq name (shepherd-service-provision s)))
        (shepherd-configuration-services
         (service-value
          (fold-services (operating-system-services %os)
                         #:target-type shepherd-root-service-type)))))

(define %mihomo-daemon
  (shepherd-service-with-provision 'mihomo))
(define %mihomo-config-svc
  (shepherd-service-with-provision 'mihomo-config-ready))

(test-assert "M11: mihomo daemon requires config-ready + networking"
             (let ((req (shepherd-service-requirement %mihomo-daemon)))
               (and (memq 'mihomo-config-ready req)
                    (memq 'networking req)
                    (memq 'loopback req))))
(test-assert "M11: materializer requires ordinary-secrets-ready"
             (memq 'ordinary-secrets-ready
                   (shepherd-service-requirement %mihomo-config-svc)))
(test-assert "M11: materializer is one-shot"
             (shepherd-service-one-shot? %mihomo-config-svc))
(test-assert "M11: daemon start uses -d data dir and -f runtime config"
             (let ((sexp (object->string
                          (gexp->approximate-sexp
                           (shepherd-service-start %mihomo-daemon)))))
               (and (string-contains sexp "/var/lib/clash")
                    (string-contains sexp "-f")
                    (string-contains sexp "/run/mihomo/config.yaml"))))

;; ── M12：account / machine-state rule ───────────────────────
(test-assert "M12: clash system group in folded accounts"
             (let ((accounts (service-value
                              (fold-services
                               (operating-system-services %os)
                               #:target-type account-service-type))))
               (and (find (lambda (g)
                            (and (user-group? g)
                                 (string=? "clash" (user-group-name g))
                                 (user-group-system? g)))
                          accounts)
                    #t)))
(test-assert "M12: providers machine-state rule is valid"
             (valid-machine-state-persistence-rule?
              %mihomo-providers-persistence-rule))
(test-assert "M12: providers rule targets /var/lib/clash/providers"
             (and (string=? (machine-state-persistence-rule-backing
                             %mihomo-providers-persistence-rule)
                            "mihomo/providers")
                  (string=? (machine-state-persistence-rule-consumer
                             %mihomo-providers-persistence-rule)
                            "/var/lib/clash/providers")))

;; ── M13：subscription secret 归 mihomo 模块（无 host 层）─────
(test-assert "M13: subscription secret declared by the mihomo module"
             (let ((d (car %mihomo-secrets)))
               (and (eq? 'mihomo-subscription (secret-decl-name d))
                    (eq? 'system (secret-decl-scope d))
                    (eq? 'ordinary (secret-decl-domain d))
                    (string=? "mihomo-subscription.url"
                              (secret-decl-target-name d))
                    (string-contains
                     (local-file-absolute-file-name (secret-decl-source d))
                     "/mihomo/secrets/"))))

(test-end "mihomo")
