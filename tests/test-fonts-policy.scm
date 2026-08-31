;;; 字体策略共享接口测试：(guixcfg fonts fontconfig-policy) 的 %fontconfig-snippets
;;; 是 generic-family/fallback 策略的唯一事实源，由两个渲染器消费：
;;;   - (guixcfg home fonts) 的 home-fontconfig 服务（用户配置）；
;;;   - ONLYOFFICE 兼容层的进程内嵌 fontconfig 文件（其进程不应用
;;;     conf.d/用户配置的 include——策略必须内联，审计见
;;;     apps/onlyoffice/definition.scm 头部）。

(use-modules (guix store)
             (guix monads)
             (guix derivations)
             (guix gexp)
             (guixcfg fonts fontconfig-policy) ; %fontconfig-snippets（接口）
             (guixcfg home fonts)         ; %fontconfig-service（消费方 1）
             (gnu services)               ; service-value
             (ice-9 rdelim)               ; read-string
             (srfi srfi-1)
             (srfi srfi-13)               ; string-contains
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "fonts-policy")

(test-assert "policy snippets are a non-empty SXML list"
             (and (pair? %fontconfig-snippets)
                  (every list? %fontconfig-snippets)))

(test-assert "home fontconfig service consumes the shared snippets verbatim"
             (equal? %fontconfig-snippets
                     (service-value %fontconfig-service)))

;; ONLYOFFICE 专属 fontconfig 文件（消费方 2）：内联策略 + 无 include。
(define %store (open-connection))

(define %oo-fonts-conf
  (let ((drv (run-with-store %store
               (lower-object (@@ (guixcfg apps onlyoffice definition)
                                 onlyoffice-fontconfig-file)))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define %oo-content (call-with-input-file %oo-fonts-conf read-string))

(test-assert "onlyoffice config inlines the shared sans-serif policy"
             (and (string-contains %oo-content "<family>sans-serif</family>")
                  (string-contains %oo-content "<family>MiSans</family>")))
(test-assert "onlyoffice config inlines the shared monospace policy"
             (and (string-contains %oo-content "<family>monospace</family>")
                  (string-contains %oo-content
                                   "<family>Maple Mono Normal NL NF CN</family>")))
(test-assert "onlyoffice config has the same dir set as the virelith default"
             (and (string-contains %oo-content "font-dejavu")
                  (string-contains %oo-content "prefix=\"xdg\"")
                  (string-contains %oo-content "~/.fonts")))
(test-assert "onlyoffice config contains no include (inlining is the contract)"
             (not (string-contains %oo-content "<include")))

(test-end "fonts-policy")
