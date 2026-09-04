;;; /etc/profile ownership 测试（2026-09 登录链审计）：
;;;   - 唯一 owner：Guix Home 激活 = ~/.profile → setup-environment；
;;;   - 唯一 owner：system /etc/profile = (guixcfg system profile)
;;;     ——pinned guix 模板逐字一致，唯删除 user-profile loop 里的
;;;     guix-home 条目（消除同一 login shell 内 guix-home
;;;     etc/profile 被 source 两次的拓扑重复；不做运行时去重）。
;;;
;;; 覆盖：
;;;   PR1  repo 模板 = pinned 模板减去 guix-home loop 条目（关键
;;;        段落仍在：system profile 激活、guix-profile/current
;;;        loop、privileged PATH、profile.d、bashrc）；
;;;   PR2  VM 与 Laptop 的 etc-service value 恰好一个 'profile
;;;        条目且为仓库模板（上游条目被替换，不并存）。

(use-modules (guixcfg system profile)
             (guixcfg hosts vm)
             (guixcfg hosts laptop)
             (gnu services)          ; etc-service-type、service-kind、service-value
             (gnu system)            ; operating-system-services
             (ice-9 rdelim)          ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "profile")

(define %profile-text
  (call-with-input-file "modules/guixcfg/system/profile"
                        (lambda (p) (read-string p))))

;; ── PR1：模板内容契约 ──────────────────────────────────────
(test-assert "PR1: repo /etc/profile does not activate the Guix Home profile"
             ;; 删除错误的第二 source：loop 不得出现 guix-home。
             (not (string-contains %profile-text ".guix-home/profile")))

(test-assert "PR1: system activation parts remain (system profile, \
guix-profile/current loop, privileged PATH, profile.d, bashrc)"
             (and (string-contains %profile-text
                                   "/run/current-system/profile/etc/profile")
                  (string-contains %profile-text "\"$HOME/.guix-profile\"")
                  (string-contains %profile-text
                                   "\"$HOME/.config/guix/current\"")
                  (string-contains %profile-text "/run/privileged/bin")
                  (string-contains %profile-text "/etc/profile.d/*.sh")
                  (string-contains %profile-text "/etc/bashrc")))

;; ── PR2：host 装配（唯一 'profile 条目）────────────────────
(define (etc-entries os)
  (service-value
   (fold-services (operating-system-services os)
                  #:target-type etc-service-type)))

(test-assert "PR2: both hosts carry exactly one /etc/profile entry, the repo's"
             (let ((results
                    (map (lambda (os)
                           (let* ((entries (etc-entries os))
                                  (profiles
                                   (filter (lambda (e)
                                             (string=? "profile" (car e)))
                                           entries)))
                             (and (= 1 (length profiles))
                                  ;; 条目形态与上游一致：("profile"
                                  ;; obj)——file 在 cadr（cdr 是
                                  ;; 单元素列表）。
                                  (string=?
                                   (object->string (cadar profiles))
                                   (object->string %system-profile)))))
                         (list %vm-os %laptop-os))))
               (and (= 2 (length results))
                    (every identity results))))

(test-end "profile")
