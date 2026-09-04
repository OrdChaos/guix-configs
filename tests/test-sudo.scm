;;; sudo 机器策略测试：/etc/sudoers Defaults 声明（2026-09）。
;;; 内容静态 → colocate 文件 modules/guixcfg/system/sudo/sudoers
;;; （local-file），测试直接读仓库源文件（SU1）与 lower 后的
;;; store 产物（SU2）。
;;;
;;; 覆盖：
;;;   SU1  sudoers 内容 = guix 默认规则（root + %wheel ALL）
;;;        + lecture=never + passprompt（%p = 被请求密码的用户名，
;;;        与 Arch "[sudo] password for %p:" 同风格；自定义字符串
;;;        不经 gettext——locale 固定 zh_CN，硬编码一致）；
;;;   SU2  VM 与 Laptop 的 OS 都装配仓库 sudoers（lower 后读内容，
;;;        不依赖 record 类型身份）。

(use-modules (guixcfg system sudo policy)
             (guixcfg hosts vm)
             (guixcfg hosts laptop)
             (gnu system)          ; operating-system-sudoers-file
             (guix gexp)           ; lower-object
             (guix monads)
             (guix store)
             (ice-9 rdelim)        ; read-string
             (ice-9 textual-ports) ; get-string-all
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "sudo")

(define %store (open-connection))

(define (lower-text file-like)
  "lower FILE-LIKE 并读 store 内容（test-smartdns 同款模式）。"
  (call-with-input-file
   (run-with-store %store (lower-object file-like))
   get-string-all))

;; ── SU1：内容契约（读仓库源文件）───────────────────────────
(define %sudoers-text
  (call-with-input-file "modules/guixcfg/system/sudo/sudoers"
                        (lambda (p) (read-string p))))

(test-assert "SU1: sudoers keeps the guix default rules (root + %wheel ALL)"
             (and (string-contains %sudoers-text "root ALL=(ALL) ALL")
                  (string-contains %sudoers-text "%wheel ALL=(ALL) ALL")))

(test-assert "SU1: lecture = never (stateless root: lectured db is ephemeral)"
             (string-contains %sudoers-text
                              "Defaults lecture = never"))

(test-assert "SU1: passprompt is the bracketed zh prompt (%p = requester user)"
             (and (string-contains %sudoers-text
                                   "Defaults passprompt = ")
                  (string-contains %sudoers-text
                                   "[sudo] %p 的密码：")))

;; ── SU2：host 装配（lower 后读 store 内容）─────────────────
(test-assert "SU2: both hosts assemble the repo sudoers file"
             (let ((vm-s (lower-text
                          (operating-system-sudoers-file %vm-os)))
                   (lp-s (lower-text
                          (operating-system-sudoers-file %laptop-os))))
               (and (string-contains vm-s "Defaults lecture = never")
                    (string-contains lp-s "Defaults lecture = never")
                    (string-contains vm-s "[sudo] %p 的密码：")
                    (string-contains lp-s "[sudo] %p 的密码："))))

(test-end "sudo")
