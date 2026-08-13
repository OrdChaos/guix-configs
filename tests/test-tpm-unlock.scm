;;; boot/tpm-unlock.scm 的单元测试。由 tests/run-tests.scm 加载运行。
;;; 覆盖：cmdline 解析（recovery / 显式禁用）、tpm-unlock-candidate?
;;; 决策（recovery → 禁用、TPM 不可用 → 回退、artifact 缺失 → 回退）。

(use-modules (guixcfg boot tpm-unlock)
             (srfi srfi-64))

(test-begin "tpm-unlock")

;; ── cmdline 解析（纯函数）────────────────────────────────
(test-equal "rootmode=recovery 可识别"
            "recovery"
            (cmdline-option "root=/selected-root rootmode=recovery foo=bar"
                            "rootmode"))
(test-equal "rootmode=keep:3 可识别"
            "keep:3"
            (cmdline-option "rootmode=keep:3" "rootmode"))
(test-equal "guixcfg.tpm-unlock=0 可识别"
            "0"
            (cmdline-option "guixcfg.tpm-unlock=0" "guixcfg.tpm-unlock"))
(test-assert "不存在的选项返回 #f"
             (not (cmdline-option "root=/x" "rootmode")))
(test-assert "空 cmdline 返回 #f"
             (not (cmdline-option "" "rootmode")))
(test-assert "选项值前缀不误匹配（rootmode2= 不是 rootmode）"
             (not (cmdline-option "rootmode2=foo" "rootmode")))

;; ── 决策纯函数 ────────────────────────────────────────────
(test-assert "正常 + TPM 可用 + artifact 完整 → 尝试 TPM"
             (tpm-unlock-candidate? #f #t #t))
(test-assert "Recovery → 不尝试 TPM"
             (not (tpm-unlock-candidate? #t #t #t)))
(test-assert "TPM 不可用 → 回退密码"
             (not (tpm-unlock-candidate? #f #f #t)))
(test-assert "artifact 缺失 → 回退密码"
             (not (tpm-unlock-candidate? #f #t #f)))
(test-assert "artifact 部分（只 pub）→ 回退密码"
             (not (tpm-unlock-candidate? #f #t #f)))

;; ── Recovery 门控的完整判定（cmdline 字符串层面）────────
(define (recovery-cmdline? line)
  (let ((raw-mode (cmdline-option line "rootmode"))
        (tpm-off (cmdline-option line "guixcfg.tpm-unlock")))
    (or (and tpm-off (string=? tpm-off "0"))
        (and raw-mode (string-prefix? "recovery" raw-mode)))))

(test-assert "rootmode=recovery → 门控禁用 TPM"
             (recovery-cmdline? "rootmode=recovery"))
(test-assert "guixcfg.tpm-unlock=0 → 门控禁用 TPM"
             (recovery-cmdline? "guixcfg.tpm-unlock=0"))
(test-assert "普通启动 → 不门控"
             (not (recovery-cmdline? "root=/selected-root rootmode=keep:3")))
(test-assert "rootmode=keep（非 recovery）→ 不门控"
             (not (recovery-cmdline? "rootmode=keep")))

(test-end)
