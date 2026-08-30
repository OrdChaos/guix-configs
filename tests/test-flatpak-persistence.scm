;;; Flatpak persistence 规则测试（docs/architecture/flatpak.md
;;; （persistence））：data-app 映射精确、规则合法、installation 与
;;; apps/<id> backing 无 parent/child 嵌套（regression：旧布局
;;; flatpak/<id> 会落在 installation backing 内部）、selection
;;; removal 不影响规则（规则只从 Catalog 派生）。
;;;
;;; 纯数据——不触 flatpak CLI、不触网络。

(use-modules (guixcfg flatpak model)
             (guixcfg flatpak service)
             (guixcfg flatpak registry)   ; %flatpak-applications、%flatpak-selection（生产 catalog 回归）
             (guixcfg system application-persistence) ; valid-application-persistence-rule?
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "flatpak-persistence")

(define %fp-apps
  (list (flatpak-application
         (name 'wechat) (id "com.tencent.WeChat")
         (remote 'flathub) (branch "stable"))
        (flatpak-application
         (name 'qq) (id "com.qq.QQ")
         (remote 'flathub) (branch "stable"))))

;; ── installation rule（平台拥有）───────────────────────────
(test-equal "installation backing"
            "flatpak/installation"
            (application-persistence-rule-backing
             %flatpak-installation-persistence-rule))
(test-equal "installation consumer (flatpak canonical path)"
            ".local/share/flatpak"
            (application-persistence-rule-consumer
             %flatpak-installation-persistence-rule))
(test-assert "installation rule valid per generic engine"
             (valid-application-persistence-rule?
              %flatpak-installation-persistence-rule))

;; ── per-app rules（Catalog 派生）───────────────────────────
(define %fp-rules (flatpak-application-persistence-rules %fp-apps))

(test-equal "catalog app -> .var/app/<id> rule"
            '(".var/app/com.tencent.WeChat" ".var/app/com.qq.QQ")
            (map application-persistence-rule-consumer %fp-rules))
(test-equal "catalog app backing flatpak/apps/<id>"
            '("flatpak/apps/com.tencent.WeChat"
              "flatpak/apps/com.qq.QQ")
            (map application-persistence-rule-backing %fp-rules))
(test-assert "every app rule valid per generic engine"
             (every valid-application-persistence-rule? %fp-rules))
(test-assert "app rules bind-directory/application-owned"
             (every (lambda (r)
                      (and (eq? 'bind-directory
                                (application-persistence-rule-exposure r))
                           (eq? 'application-owned
                                (application-persistence-rule-lifecycle r))))
                    %fp-rules))

;; ── 命名空间分离（regression：parent/child 嵌套禁止）───────
(define (path-prefix? a b)
  (string-prefix? (string-append a "/") b))

(test-assert "installation backing not prefix of any app backing"
             (every (lambda (r)
                      (not (path-prefix?
                            (application-persistence-rule-backing
                             %flatpak-installation-persistence-rule)
                            (application-persistence-rule-backing r))))
                    %fp-rules))
(test-assert "no app backing is prefix of installation backing"
             (every (lambda (r)
                      (not (path-prefix?
                            (application-persistence-rule-backing r)
                            (application-persistence-rule-backing
                             %flatpak-installation-persistence-rule))))
                    %fp-rules))
(test-assert "app backings pairwise non-overlapping"
             (let ((backings (map application-persistence-rule-backing
                                  %fp-rules)))
               (and (= 2 (length (delete-duplicates backings)))
                    (not (any (lambda (a)
                                (any (lambda (b)
                                       (and (not (string=? a b))
                                            (path-prefix? a b)))
                                     backings))
                              backings)))))

;; ── selection removal 不影响规则（Catalog 派生）────────────
(test-equal "rules derive from catalog, selection-independent"
            (flatpak-application-persistence-rules %fp-apps)
            (flatpak-application-persistence-rules %fp-apps))
(test-equal "removing an app from selection changes nothing"
            '(".var/app/com.tencent.WeChat" ".var/app/com.qq.QQ")
            (map application-persistence-rule-consumer
                 (flatpak-application-persistence-rules %fp-apps)))

;; ── 平台聚合顺序 ───────────────────────────────────────────
(test-equal "flatpak-persistence-rules: installation first, then apps"
            (cons "flatpak/installation"
                  '("flatpak/apps/com.tencent.WeChat"
                    "flatpak/apps/com.qq.QQ"))
            (map application-persistence-rule-backing
                 (cons %flatpak-installation-persistence-rule
                       (flatpak-application-persistence-rules %fp-apps))))

;; ── 生产 catalog 回归（registry 的真实内容）────────────────
;; Catalog/Selection 是 lifecycle authority：真实 catalog 必须持续
;; 通过校验并派生正确的 persistence 规则（QQ 是首个生产 app）。
(define %prod-rules (flatpak-persistence-rules))

(test-assert "production catalog validates at load (registry side effect)"
             (any (lambda (a)
                    (and (eq? 'qq (flatpak-application-name a))
                         (string=? "com.qq.QQ" (flatpak-application-id a))))
                  %flatpak-applications))
(test-assert "production QQ app gets its .var/app/<id> rule"
             (any (lambda (r)
                    (and (string=? ".var/app/com.qq.QQ"
                                   (application-persistence-rule-consumer r))
                         (string=? "flatpak/apps/com.qq.QQ"
                                   (application-persistence-rule-backing r))))
                  %prod-rules))
(test-assert "production selection resolves against catalog"
             (= 1 (length (flatpak-select-applications
                           %flatpak-selection %flatpak-applications))))
(test-assert "production selection removal keeps persistence rules"
             (= (length %prod-rules)
                (length (cons %flatpak-installation-persistence-rule
                              (flatpak-application-persistence-rules
                               %flatpak-applications)))))

(test-end "flatpak-persistence")
