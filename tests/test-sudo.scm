;;; sudo 机器策略测试：/etc/sudoers Defaults 声明（2026-09）。
;;;
;;; 覆盖：
;;;   SU1  %sudoers-file 内容 = guix 默认规则（root + %wheel ALL）
;;;        + lecture=never + passprompt（%p = 被请求密码的用户名，
;;;        与 Arch "[sudo] password for %p:" 同风格；自定义字符串
;;;        不经 gettext——locale 固定 zh_CN，硬编码一致）；
;;;   SU2  VM 与 Laptop 的 OS 都装配仓库 sudoers（object->string
;;;        断言——跨编译单元 record 身份陷阱，不用 eq?/accessor）。

(use-modules (guixcfg system sudo)
             (guixcfg hosts vm)
             (guixcfg hosts laptop)
             (gnu system)          ; operating-system-sudoers-file
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "sudo")

;; ── SU1：内容契约 ──────────────────────────────────────────
(define %sudoers-text (object->string %sudoers-file))

(test-assert "SU1: sudoers keeps the guix default rules (root + %wheel ALL)"
             (and (string-contains %sudoers-text "root ALL=(ALL) ALL")
                  (string-contains %sudoers-text "%wheel ALL=(ALL) ALL")))

(test-assert "SU1: lecture = never (stateless root: lectured db is ephemeral)"
             (string-contains %sudoers-text
                              "Defaults lecture = never"))

(test-assert "SU1: passprompt is the bracketed zh prompt (%p = requester user)"
             ;; object->string 把内容按 Scheme 字面量打印（内嵌引号
             ;; 转义为 \"）——按无引号片段断言，避免转义形态耦合。
             (and (string-contains %sudoers-text
                                   "Defaults passprompt = ")
                  (string-contains %sudoers-text
                                   "[sudo] %p 的密码：")))

;; ── SU2：host 装配 ─────────────────────────────────────────
(test-assert "SU2: both hosts assemble the repo sudoers file"
             (let ((vm-s (object->string
                          (operating-system-sudoers-file %vm-os)))
                   (lp-s (object->string
                          (operating-system-sudoers-file %laptop-os))))
               (and (string-contains vm-s "Defaults lecture = never")
                    (string-contains lp-s "Defaults lecture = never")
                    (string-contains vm-s "[sudo] %p 的密码：")
                    (string-contains lp-s "[sudo] %p 的密码："))))

(test-end "sudo")
