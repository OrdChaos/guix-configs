;;; 字体策略共享接口测试：(guixcfg fonts fontconfig-policy) 的
;;; %fontconfig-snippets 是 generic-family/fallback 策略的唯一事实源，
;;; 由 (guixcfg home fonts) 的 home-fontconfig 服务消费（Flatpak 沙箱
;;; 的字体走 pinned flatpak-fix-fonts-icons.patch 绑定 system profile，
;;; 不消费本策略）。这里只断言策略数据本身，不依赖任何具体应用。

(use-modules (guixcfg fonts fontconfig-policy) ;%fontconfig-snippets（接口）
             (sxml simple) ;sxml->xml
             (srfi srfi-1)
             (srfi srfi-13) ;string-contains
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "fonts-policy")

(test-assert "policy snippets are a non-empty SXML list"
             (and (pair? %fontconfig-snippets)
                  (every list? %fontconfig-snippets)))

(define %policy-xml
  (call-with-output-string
   (lambda (port)
     (for-each (lambda (snippet)
                 (sxml->xml snippet port)) %fontconfig-snippets))))

(test-assert "sans-serif chain starts at MiSans"
             (string-contains %policy-xml "<family>MiSans</family>"))
(test-assert "monospace chain includes Maple Mono"
             (string-contains %policy-xml
                              "<family>Maple Mono Normal NL NF CN</family>"))
(test-assert "CSS UI generic names are rewritten"
             (and (string-contains %policy-xml
                                   "<string>ui-sans-serif</string>")
                  (string-contains %policy-xml
                                   "<string>ui-monospace</string>")
                  (string-contains %policy-xml "mode=\"assign_replace\"")))

(test-end "fonts-policy")
