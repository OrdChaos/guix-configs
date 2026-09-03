;;; (guixcfg security enroll) 编排层测试：纯分类 / 计划输出 / 固件确认
;;; 匹配 / tpm2 argv / 事务 root gate。
;;;
;;; 全部断言只走纯路径（分类 alist、计划行、argv、非 root 事务的
;;; fail-closed 前置）——绝不触碰真实 TPM / LUKS keyslot / NVRAM /
;;; sbkeysync。

(use-modules (guixcfg security enroll)
             (srfi srfi-64)
             (srfi srfi-1)
             (srfi srfi-13))

(test-runner-current (test-runner-simple))

(define %root "/repo")

(define (probes-with . overrides)
  ;; acons 前插覆盖（assq-ref 命中最前条目）；禁止 assoc-set! 改写
  ;; 共享常量（测试间污染，已实测）。
  (fold (lambda (kv acc) (acons (car kv) (cdr kv) acc))
        (list (cons 'tpm 'absent) (cons 'firmware 'setup-mode)
              (cons 'sb-keys #t) (cons 'keystore #t)
              (cons 'facts #t) (cons 'sbkeysync #t)
              (cons 'tpm-device #t) (cons 'current-system #t)
              (cons 'persist #t) (cons 'esp #t))
        overrides))

(test-begin "enroll-orchestration")

;;; ────────────────────────────────────────────────────────────
;;; efi-variable-byte（不存在的变量确定性返回 #f）

(test-assert "efi variable probe returns #f for a nonexistent variable"
             (not (efi-variable-byte "Guixcfg-Does-Not-Exist")))

;;; ────────────────────────────────────────────────────────────
;;; 纯分类：固件 / TPM / idempotency

(define (status-of . overrides)
  (classify-enrollment-probes (apply probes-with overrides)))

(test-equal "enrolled firmware: SecureBoot=1 SetupMode=0"
            'enrolled
            (enrollment-status-firmware (status-of '(firmware . enrolled))))

(test-equal "setup-mode firmware: SecureBoot=0 SetupMode=1"
            'setup-mode
            (enrollment-status-firmware (status-of '(firmware . setup-mode))))

(test-equal "unclear firmware state is not guessed"
            'unclear
            (enrollment-status-firmware (status-of '(firmware . unclear))))

(test-equal "pending-reboot firmware state passes through classification"
            'pending-reboot
            (enrollment-status-firmware
             (status-of '(firmware . pending-reboot))))

(test-equal "TPM absent"
            'absent
            (enrollment-status-tpm (status-of '(tpm . absent))))

(test-equal "TPM compatible"
            'compatible
            (enrollment-status-tpm (status-of '(tpm . compatible))))

(test-equal "TPM incomplete (artifacts missing) is NOT auto-replaced"
            'incomplete
            (enrollment-status-tpm (status-of '(tpm . incomplete))))

(test-equal "TPM unreadable"
            'unreadable
            (enrollment-status-tpm (status-of '(tpm . unreadable))))

;;; ────────────────────────────────────────────────────────────
;;; 计划输出（§24 格式）

(define %enroll-status (status-of))

(define plan-text
  (string-join (enroll-plan-lines %enroll-status "laptop") "\n"))

(test-assert "enroll plan shows host"
             (string-contains plan-text "Host: laptop"))

(test-assert "enroll plan shows TPM device and action"
             (and (string-contains plan-text "/dev/tpmrm0")
                  (string-contains plan-text "not enrolled")
                  (string-contains plan-text
                                  "enroll using current policy")))

(test-assert "enroll plan shows Secure Boot section"
             (and (string-contains plan-text "Secure Boot:")
                  (string-contains plan-text "Setup Mode")))

(test-assert "enroll plan lists the mutation classes"
             (and (string-contains plan-text "LUKS keyslot")
                  (string-contains plan-text "TPM sealed state")
                  (string-contains plan-text "firmware NVRAM")))

(test-assert "enroll plan marks an incompatible TPM as BLOCKED"
             (let ((text (string-join
                          (enroll-plan-lines
                           (status-of '(tpm . incomplete)) "laptop")
                          "\n")))
               (string-contains text "BLOCKED (incompatible enrollment")))

(test-assert "enroll plan marks unclear firmware as BLOCKED"
             (let ((text (string-join
                          (enroll-plan-lines
                           (status-of '(firmware . unclear)) "laptop")
                          "\n")))
               (string-contains text "BLOCKED (firmware state unclear)")))

(test-assert "enroll plan marks pending-reboot firmware as awaiting reboot (not blocked)"
             (let ((text (string-join
                          (enroll-plan-lines
                           (status-of '(firmware . pending-reboot)) "laptop")
                          "\n")))
               (and (string-contains text
                                     "reboot to activate Secure Boot")
                    (not (string-contains text "BLOCKED")))))

;;; ────────────────────────────────────────────────────────────
;;; 固件确认匹配（§23/§36）

(test-assert "firmware confirmation accepts the exact token"
             (firmware-confirmed? "ENROLL-FIRMWARE"))

(test-assert "firmware confirmation rejects a bare yes"
             (not (firmware-confirmed? "y")))

(test-assert "firmware confirmation rejects empty input"
             (not (firmware-confirmed? "")))

(test-assert "firmware confirmation rejects EOF"
             ;; EOF object 经空字符串端口 read 得到——不依赖
             ;; run-tests.scm 模块上下文的 eof-object 绑定。
             (not (firmware-confirmed?
                   (call-with-input-string "" read))))

(test-assert "firmware confirmation rejects non-string input"
             (not (firmware-confirmed? #f)))

(test-assert "firmware confirm UI states current state, planned op and rollback implication"
             (let ((text (string-join
                          (firmware-confirm-lines
                           (status-of '(firmware . setup-mode)))
                          "\n")))
               (and (string-contains text "Setup Mode")
                    (string-contains text "db, KEK, PK")
                    (string-contains text "exits Setup Mode")
                    (string-contains text "Rollback/recovery implication")
                    (string-contains text "ENROLL-FIRMWARE"))))

;;; ────────────────────────────────────────────────────────────
;;; argv（纯）

(define tpm-argv (tpm2-tool-argv %root "/store/guile/bin/guile"
                                 "/store/guix/share/guile/site/3.0"
                                 "status" '()))

(test-assert "tpm2 tool argv runs guix's own guile (not guix repl)"
             (and (equal? (car tpm-argv) "/store/guile/bin/guile")
                  (member "--no-auto-compile" tpm-argv)
                  (member "-s" tpm-argv)))

(test-assert "tpm2 tool argv loads the guix site and repo modules"
             (and (equal? "/store/guix/share/guile/site/3.0"
                          (and=> (member "-L" tpm-argv) cadr))
                  (member "/repo/modules" tpm-argv)))

(test-equal "tpm2 tool argv ends with the script, action and flags"
            '("-s" "/repo/tools/tpm2-enroll.scm" "status")
            (let ((tail (member "-s" tpm-argv)))
              (take tail 3)))

(test-equal "enroll action argv carries --luks-secret as a separate flag"
            '("enroll" "--luks-secret")
            (let ((argv (tpm2-tool-argv %root "/g" "/s"
                                        "enroll" '("--luks-secret"))))
              (take (cddr (member "-s" argv)) 2)))

(test-equal "sbkeysync binary defaults to the system profile"
            "/run/current-system/profile/bin/sbkeysync"
            (sbkeysync-binary))

;;; ────────────────────────────────────────────────────────────
;;; 只读检查形态（soft 语义：本机不是目标系统 → 硬性环境项 fail）

(test-assert "enroll readonly checks are ((label . thunk)) with ok/info/fail results"
             (let ((checks (enroll-readonly-checks "/repo" "laptop")))
               (every (lambda (check)
                        (and (pair? check)
                             (string? (car check))
                             (procedure? (cdr check))
                             (let ((r ((cdr check))))
                               (and (pair? r)
                                    (memq (car r) '(ok info fail))))))
                      checks)))

;; SB 材料检查的 fail/info 边界（2026-09 VM 实测教训：普通用户面对
;; 0700 root keydir 曾被误报为 missing——不可读 ≠ 不存在；但真缺失
;; 必须 fail，soft 态也不得伪装成「需 root」）。本机 /persist 不存在
;; = 真缺失 → fail。
(define* (enroll-check-status label #:key (soft? #t))
  (let ((check (find (lambda (c) (string=? (car c) label))
                     (enroll-readonly-checks "/repo" "laptop"
                                             #:soft? soft?))))
    (car ((cdr check)))))

(test-equal "SB keys check fails closed when the keydir is truly absent (soft mode)"
            'fail
            (enroll-check-status "Secure Boot keys"))

(test-equal "SB keystore check fails closed when the keystore is truly absent (soft mode)"
            'fail
            (enroll-check-status "Secure Boot keystore"))

(test-equal "SB keys check fails closed in hard (root) mode when absent"
            'fail
            (enroll-check-status "Secure Boot keys" #:soft? #f))

(test-equal "SB keystore check fails closed in hard (root) mode when absent"
            'fail
            (enroll-check-status "Secure Boot keystore" #:soft? #f))

;;; ────────────────────────────────────────────────────────────
;;; 事务 root gate（非 root 立即 1，绝不触碰 exec / confirm）

(define (exploding-exec . argv)
  (error "exec must not be called before the root gate"))

(define (exploding-confirm status)
  (error "confirm must not be called before the root gate"))

(test-equal "enroll transaction refuses non-root with exit 1 (no exec)"
            1
            (enroll-transaction! "/repo" "laptop"
                                 #:exec exploding-exec
                                 #:on-firmware-confirm exploding-confirm))

(test-end "enroll-orchestration")
