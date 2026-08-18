;;; boot/tpm-unlock.scm 的单元测试。由 tests/run-tests.scm 加载运行。
;;; 覆盖：cmdline 解析（recovery / 显式禁用）、tpm-unlock-candidate?
;;; 决策（recovery → 禁用、TPM 不可用 → 回退、artifact 缺失 → 回退）。

(use-modules (guixcfg boot tpm-unlock)
             (srfi srfi-64))

(test-begin "tpm-unlock")

;; ── cmdline 解析（纯函数）────────────────────────────────
(test-equal "rootmode=recovery recognized"
            "recovery"
            (cmdline-option "root=/selected-root rootmode=recovery foo=bar"
                            "rootmode"))
(test-equal "rootmode=normal recognized"
            "normal"
            (cmdline-option "rootmode=normal" "rootmode"))
(test-equal "guixcfg.tpm-unlock=0 recognized"
            "0"
            (cmdline-option "guixcfg.tpm-unlock=0" "guixcfg.tpm-unlock"))
(test-assert "absent option returns #f"
             (not (cmdline-option "root=/x" "rootmode")))
(test-assert "empty cmdline returns #f"
             (not (cmdline-option "" "rootmode")))
(test-assert "prefix not mis-matched (rootmode2= is not rootmode)"
             (not (cmdline-option "rootmode2=foo" "rootmode")))

;; ── 决策纯函数 ────────────────────────────────────────────
(test-assert "normal + TPM available + artifact complete -> tries TPM"
             (tpm-unlock-candidate? #f #t #t))
(test-assert "Recovery -> skips TPM"
             (not (tpm-unlock-candidate? #t #t #t)))
(test-assert "TPM unavailable -> passphrase fallback"
             (not (tpm-unlock-candidate? #f #f #t)))
(test-assert "artifact missing -> passphrase fallback"
             (not (tpm-unlock-candidate? #f #t #f)))
(test-assert "partial artifact (pub only) -> passphrase fallback"
             (not (tpm-unlock-candidate? #f #t #f)))

;; ── Recovery 门控的完整判定（cmdline 字符串层面）────────
(define (recovery-cmdline? line)
  (let ((raw-mode (cmdline-option line "rootmode"))
        (tpm-off (cmdline-option line "guixcfg.tpm-unlock")))
    (or (and tpm-off (string=? tpm-off "0"))
        (and raw-mode (string-prefix? "recovery" raw-mode)))))

(test-assert "rootmode=recovery -> gate disables TPM"
             (recovery-cmdline? "rootmode=recovery"))
(test-assert "guixcfg.tpm-unlock=0 -> gate disables TPM"
             (recovery-cmdline? "guixcfg.tpm-unlock=0"))
(test-assert "normal boot -> not gated"
             (not (recovery-cmdline? "root=/selected-root rootmode=normal")))
(test-assert "rootmode=normal (non-recovery) -> not gated"
             (not (recovery-cmdline? "rootmode=normal")))

(test-end)
