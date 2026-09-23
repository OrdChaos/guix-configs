;;; (guixcfg security enroll) 编排层测试：纯分类 / 计划输出 / 固件确认
;;; 匹配 / tpm2 argv / 事务 root gate。
;;;
;;; 全部断言只走纯路径（分类 alist、计划行、argv、非 root 事务的
;;; fail-closed 前置）——绝不触碰真实 TPM / LUKS keyslot / NVRAM /
;;; sbkeysync。

(use-modules (guixcfg security enroll)
             (srfi srfi-64)
             (srfi srfi-1)
             (srfi srfi-13)
             (rnrs bytevectors))

(test-runner-current (test-runner-simple))

(define %root "/repo")

(define (probes-with . overrides)
  ;; acons 前插覆盖（assq-ref 命中最前条目）；禁止 assoc-set! 改写
  ;; 共享常量（测试间污染，已实测）。
  (fold (lambda (kv acc) (acons (car kv) (cdr kv) acc))
        (list (cons 'tpm 'absent) (cons 'firmware 'setup-mode)
              (cons 'sb-keys #t) (cons 'keystore #t)
              (cons 'facts #t) (cons 'sbkeysync #t)
              (cons 'tpm-device #t) (cons 'tpm-artifacts #f)
              (cons 'current-system #t)
              (cons 'persist #t) (cons 'esp #t))
        overrides))

(test-begin "enroll-orchestration")

;;; ────────────────────────────────────────────────────────────
;;; efi-variable-byte（不存在的变量确定性返回 #f）

(test-assert "efi variable probe returns #f for a nonexistent variable"
             (not (efi-variable-byte "Guixcfg-Does-Not-Exist")))

(test-eq "unreadable EFI variables produce unclear firmware state"
         'unclear
         (secure-boot-firmware-state (lambda (name) #f)))

(test-eq "readable EFI variables classify enrolled firmware"
         'enrolled
         (secure-boot-firmware-state
          (lambda (name)
            (cond ((string=? name "SecureBoot") 1)
              ((string=? name "SetupMode") 0)
              (else 1)))
          (lambda () #t)))

(test-eq "User Mode with a foreign PK is not classified as enrolled"
         'foreign-enrolled
         (secure-boot-firmware-state
          (lambda (name)
            (cond ((string=? name "SecureBoot") 1)
              ((string=? name "SetupMode") 0)
              (else 1)))
          (lambda () #f)))

(test-eq "unprivileged PK ownership uncertainty is distinct from a mismatch"
         'enrolled-unverified
         (secure-boot-firmware-state
          (lambda (name)
            (cond ((string=? name "SecureBoot") 1)
              ((string=? name "SetupMode") 0)
              (else 1)))
          (lambda () 'unverified)))

(define %pk-fixture
  (string-append "/tmp/guixcfg-test-pk-" (number->string (getpid)) ".crt"))

(call-with-output-file %pk-fixture
                       (lambda (port)
                         (display "-----BEGIN CERTIFICATE-----\nAQIDBA==\n-----END CERTIFICATE-----\n"
                                  port)))

(define (fake-efi-pk certificate-bytes)
  ;; 4-byte efivar attributes + one 28-byte EFI_SIGNATURE_LIST header +
  ;; one EFI_SIGNATURE_DATA (16-byte owner GUID + certificate payload).
  (let* ((certificate-length (length certificate-bytes))
         (signature-size (+ 16 certificate-length))
         (list-size (+ 28 signature-size))
         (bv (make-bytevector (+ 4 list-size) 0)))
    (define (set-u32-le! offset value)
      (do ((i 0 (+ i 1)))
          ((= i 4))
        (bytevector-u8-set! bv (+ offset i)
                            (logand (ash value (* -8 i)) #xff))))
    (set-u32-le! 20 list-size)
    (set-u32-le! 24 0)
    (set-u32-le! 28 signature-size)
    (let loop ((bytes certificate-bytes) (offset 48))
      (unless (null? bytes)
        (bytevector-u8-set! bv offset (car bytes))
        (loop (cdr bytes) (+ offset 1))))
    bv))

(test-assert "EFI PK ownership check matches the exact certificate DER payload"
             (efi-variable-contains-certificate?
              "PK" %pk-fixture
              (lambda (name) (fake-efi-pk '(1 2 3 4)))))

(test-assert "EFI PK ownership check rejects a different certificate"
             (not (efi-variable-contains-certificate?
                   "PK" %pk-fixture
                   (lambda (name) (fake-efi-pk '(1 2 3 5))))))

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

(test-assert "firstboot is incomplete in Setup Mode"
             (not (firstboot-completed? (status-of))))

(test-assert "firstboot is complete after firmware PK is written"
             (firstboot-completed?
              (status-of '(firmware . pending-reboot))))

(test-assert "firstboot completion is visible to an unprivileged caller"
             (firstboot-completed?
              (status-of '(firmware . enrolled-unverified))))

(test-assert "firstboot completion requires the installed target environment"
             (not (firstboot-completed?
                   (status-of '(firmware . enrolled)
                              '(persist . #f)))))

(test-assert "enrollment is complete only with active firmware and compatible TPM"
             (enrollment-completed?
              (status-of '(firmware . enrolled)
                         '(tpm . compatible))))

(test-assert "enrollment remains incomplete before the required reboot"
             (not (enrollment-completed?
                   (status-of '(firmware . pending-reboot)
                              '(tpm . compatible)))))

(test-assert "enrollment remains incomplete without TPM artifacts"
             (not (enrollment-completed?
                   (status-of '(firmware . enrolled)
                              '(tpm . absent)))))

(test-assert "unprivileged enrollment completion uses the ESP artifact copy"
             (enrollment-completed?
              (status-of '(firmware . enrolled-unverified)
                         '(tpm . unreadable)
                         '(tpm-artifacts . #t))))

(test-assert "unreadable TPM state without ESP artifacts is not complete"
             (not (enrollment-completed?
                   (status-of '(firmware . enrolled-unverified)
                              '(tpm . unreadable)
                              '(tpm-artifacts . #f)))))

;;; ────────────────────────────────────────────────────────────
;;; 计划输出（§24 格式）

(define %enroll-status (status-of))

(define plan-text
  (string-join
   (enroll-plan-lines %enroll-status "lenovo-legion-y7000p") "\n"))

(test-assert "enroll plan shows host"
             (string-contains plan-text "Host: lenovo-legion-y7000p"))

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
                           (status-of '(tpm . incomplete))
                           "lenovo-legion-y7000p")
                          "\n")))
               (string-contains text "BLOCKED (incompatible enrollment")))

(test-assert "enroll plan marks unclear firmware as BLOCKED"
             (let ((text (string-join
                          (enroll-plan-lines
                           (status-of '(firmware . unclear))
                           "lenovo-legion-y7000p")
                          "\n")))
               (string-contains text "BLOCKED (firmware state unclear)")))

(test-assert "enroll plan marks pending-reboot firmware as awaiting reboot (not blocked)"
             (let ((text (string-join
                          (enroll-plan-lines
                           (status-of '(firmware . pending-reboot))
                           "lenovo-legion-y7000p")
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
             (let ((checks
                    (enroll-readonly-checks
                     "/repo" "lenovo-legion-y7000p")))
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
                            (enroll-readonly-checks "/repo"
                                                    "lenovo-legion-y7000p"
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
            (enroll-transaction! "/repo" "lenovo-legion-y7000p"
                                 #:exec exploding-exec
                                 #:on-firmware-confirm exploding-confirm))

(test-end "enroll-orchestration")

(false-if-exception (delete-file %pk-fixture))
