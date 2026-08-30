;;; Flatpak persistence 投影测试（docs/architecture/flatpak.md
;;; （persistence））：persistence intent 属于 application
;;; definition——默认 ~/.var/app/<id> 从 ID 推导、extra-persistence
;;; 是 definition 声明的例外；投影从 **selected** applications
;;; 派生（未选中的 catalog app 不产生 mount）；installation 与
;;; apps/<id> backing 无 parent/child 嵌套（regression：旧布局
;;; flatpak/<id> 会落在 installation backing 内部）。
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
         (remote 'flathub) (branch "stable"))
        (flatpak-application
         (name 'extra-app) (id "org.example.Extra")
         (remote 'flathub) (branch "stable")
         (extra-persistence '((".local/share/extra-app" "extra-app/share"))))))

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

;; ── default persistence：从 application ID 推导 ────────────
(define %qq-rules (flatpak-application-persistence-rules (cadr %fp-apps)))

(test-equal "default rule consumer derives from id"
            '(".var/app/com.qq.QQ")
            (map application-persistence-rule-consumer %qq-rules))
(test-equal "default rule backing derives from id"
            '("flatpak/apps/com.qq.QQ")
            (map application-persistence-rule-backing %qq-rules))
(test-assert "default rules valid per generic engine"
             (every valid-application-persistence-rule? %qq-rules))
(test-assert "default rules bind-directory/application-owned"
             (every (lambda (r)
                      (and (eq? 'bind-directory
                                (application-persistence-rule-exposure r))
                           (eq? 'application-owned
                                (application-persistence-rule-lifecycle r))))
                    %qq-rules))

;; ── extra-persistence：definition 声明的例外 ───────────────
(define %extra-rules
  (flatpak-application-persistence-rules (caddr %fp-apps)))

(test-equal "extra rule appended after default"
            '(".var/app/org.example.Extra" ".local/share/extra-app")
            (map application-persistence-rule-consumer %extra-rules))
(test-equal "extra rule backing from declaration"
            "extra-app/share"
            (application-persistence-rule-backing (cadr %extra-rules)))
(test-assert "extra rules valid per generic engine"
             (every valid-application-persistence-rule? %extra-rules))

;; ── 命名空间分离（regression：parent/child 嵌套禁止）───────
(define (path-prefix? a b)
  (string-prefix? (string-append a "/") b))

(test-assert "installation backing not prefix of any app backing"
             (every (lambda (r)
                      (not (path-prefix?
                            (application-persistence-rule-backing
                             %flatpak-installation-persistence-rule)
                            (application-persistence-rule-backing r))))
                    (append-map flatpak-application-persistence-rules
                                %fp-apps)))
(test-assert "no app backing is prefix of installation backing"
             (every (lambda (r)
                      (not (path-prefix?
                            (application-persistence-rule-backing r)
                            (application-persistence-rule-backing
                             %flatpak-installation-persistence-rule))))
                    (append-map flatpak-application-persistence-rules
                                %fp-apps)))
(test-assert "app backings pairwise non-overlapping"
             (let ((backings
                    (map application-persistence-rule-backing
                         (append-map flatpak-application-persistence-rules
                                     %fp-apps))))
               (and (= (length backings)
                       (length (delete-duplicates backings)))
                    (not (any (lambda (a)
                                (any (lambda (b)
                                       (and (not (string=? a b))
                                            (path-prefix? a b)))
                                     backings))
                              backings)))))

;; ── 投影从 selected applications 派生 ─────────────────────
(test-equal "selected app -> its persistence rules"
            '(".var/app/com.tencent.WeChat")
            (map application-persistence-rule-consumer
                 (append-map flatpak-application-persistence-rules
                             (flatpak-select-applications
                              '(wechat) %fp-apps))))
(test-equal "unselected catalog app -> no persistence rule"
            '()
            (append-map flatpak-application-persistence-rules
                        (flatpak-select-applications '() %fp-apps)))

;; ── 生产 catalog 回归（registry 的真实内容）────────────────
;; Catalog/Selection 是 lifecycle authority：真实 catalog 必须持续
;; 通过校验，QQ（selected）派生正确的默认 rule；未选中 app 不产生
;; mount（selection 驱动的投影语义）。
(define %prod-rules (flatpak-persistence-rules))

(test-assert "production catalog validates at load (registry side effect)"
             (any (lambda (a)
                    (and (eq? 'qq (flatpak-application-name a))
                         (string=? "com.qq.QQ" (flatpak-application-id a))))
                  %flatpak-applications))
(test-assert "production selection resolves against catalog"
             (= 2 (length (flatpak-selected-applications))))
(test-assert "production selected QQ gets its default .var/app rule"
             (any (lambda (r)
                    (and (string=? ".var/app/com.qq.QQ"
                                   (application-persistence-rule-consumer r))
                         (string=? "flatpak/apps/com.qq.QQ"
                                   (application-persistence-rule-backing r))))
                  %prod-rules))
(test-assert "production rules = installation + selected apps only"
             (= (+ 1 (length (flatpak-selected-applications)))
                (length %prod-rules)))
(test-assert "production selected WeChat gets its default .var/app rule"
             (any (lambda (r)
                    (and (string=? ".var/app/com.tencent.WeChat"
                                   (application-persistence-rule-consumer r))
                         (string=? "flatpak/apps/com.tencent.WeChat"
                                   (application-persistence-rule-backing r))))
                  %prod-rules))

(test-end "flatpak-persistence")
