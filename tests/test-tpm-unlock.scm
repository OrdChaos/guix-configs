;;; boot/tpm-unlock.scm 的单元测试。由 tests/run-tests.scm 加载运行。
;;; 覆盖：cmdline 解析（cmdline-option）与 cmdline 门控
;;; （tpm-unlock-disabled-by-cmdline?——生产在 tpm-unlock-in-initrd
;;; 里实际调用的同一函数；recovery/显式禁用 → 跳过 TPM）。

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

;; ── cmdline 门控（生产函数本身）──────────────────────────
(test-assert "rootmode=recovery -> gate disables TPM"
             (tpm-unlock-disabled-by-cmdline? "root=/selected-root rootmode=recovery"))
(test-assert "guixcfg.tpm-unlock=0 -> gate disables TPM"
             (tpm-unlock-disabled-by-cmdline? "guixcfg.tpm-unlock=0"))
(test-assert "normal boot -> not gated"
             (not (tpm-unlock-disabled-by-cmdline?
                   "root=/selected-root rootmode=normal")))
(test-assert "no rootmode -> not gated"
             (not (tpm-unlock-disabled-by-cmdline? "root=/selected-root")))
(test-assert "unreadable cmdline (#f) -> not gated"
             (not (tpm-unlock-disabled-by-cmdline? #f)))
(test-assert "prefix recovery* gates (rootmode=recovery-2)"
             (tpm-unlock-disabled-by-cmdline? "rootmode=recovery-2"))

(test-end)
