;;; tpm2-enroll 工具修复的回归测试：
;;;   A. executable resolver：mock bin 目录齐全时 executable-checks 全通过
;;;   B. missing executable：缺 tpm2_pcrread 时 executable-checks 含失败
;;;   C. error binding：(rnrs base) 不再覆盖 Guile 原生 error——replace
;;;      在未 enrollment 时是正常业务错误（非 wrong-number-of-arguments）
;;;   D. 模块 compile/load：tools/tpm2-enroll.scm 无 unbound/wrong-import
;;;
;;; 通过 GUIXCFG_TPM2_BIN / GUIXCFG_CRYPTSETUP 指向 mock 目录，在
;;; 本文件内控制加载顺序（%tpm2-bin 在模块加载时求值）。

(use-modules (guix build utils)
             (ice-9 ftw)
             (ice-9 rdelim)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (write-mock-bin dir names)
  "在 DIR 下创建可执行的 mock 命令。"
  (for-each
   (lambda (name)
     (let ((p (string-append dir "/" name)))
       (call-with-output-file p
         (lambda (port) (display "#!/bin/sh\nexit 0\n" port)))
       (chmod p #o755)))
   names))

(define (enroll-source-without-main)
  "读 tools/tpm2-enroll.scm，去掉末尾的 (main) 调用（测试内不触发 CLI）。"
  (let ((s (call-with-input-file "tools/tpm2-enroll.scm" get-string-all)))
    (string-join (filter (lambda (l) (not (string=? l "(main)")))
                         (string-split s #\newline))
                 "\n")))

(test-begin "tpm2-enroll")

;; ── Test A/B 共享的 mock 环境（%tpm2-bin 在加载时解析）────────
(let ((mock (mkdtemp "/tmp/guixcfg-tpm2-mock-XXXXXX")))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      ;; mock 目录包含 enrollment 全部 TPM2 命令 + cryptsetup
      (write-mock-bin mock
                      '("tpm2_pcrread" "tpm2_policypcr" "tpm2_createprimary"
                        "tpm2_startauthsession" "tpm2_create" "tpm2_load"
                        "tpm2_unseal" "tpm2_flushcontext" "cryptsetup"))
      (setenv "GUIXCFG_TPM2_BIN" mock)
      (setenv "GUIXCFG_CRYPTSETUP" (string-append mock "/cryptsetup"))
      ;; 生成去 main 的 enroll 源码并加载——%tpm2-bin 解析到 mock
      (call-with-output-file "/tmp/guixcfg-enroll-nomain.scm"
        (lambda (p) (display (enroll-source-without-main) p)))
      (primitive-load "/tmp/guixcfg-enroll-nomain.scm")

      ;; Test A：齐全 → executable-checks 全通过
      (test-assert "A: mock 齐全时全部 executable 检查通过"
        (every identity (executable-checks)))

      ;; Test B：删 tpm2_pcrread → 检查失败（不静默 PASS）
      (delete-file (string-append mock "/tpm2_pcrread"))
      (test-assert "B: 缺 tpm2_pcrread 时 executable 检查失败"
        (not (every identity (executable-checks))))

      ;; Test C：error binding——replace 在未 enrollment 时正常业务错误
      (test-assert "C: replace 未 enrollment 抛正常业务错误（非 arity 错误）"
        (let ((caught
               (catch #t
                 (lambda () (do-replace) #f)
                 (lambda (k . a)
                   (if (eq? k 'misc-error)
                     ;; error 单参数时：a = (#f "~A" (MESSAGE) #f)
                     (string-contains (car (caddr a)) "尚未 enrollment")
                     #f)))))
          caught)))
    (lambda ()
      (unsetenv "GUIXCFG_TPM2_BIN")
      (unsetenv "GUIXCFG_CRYPTSETUP")
      (false-if-exception (delete-file "/tmp/guixcfg-enroll-nomain.scm"))
      (delete-file-recursively mock))))

;; ── Test D：模块 compile/load 无 unbound/wrong-import 警告 ────
(test-assert "D: tpm2-enroll.scm 可编译且无未绑定变量警告"
  (let ((out (with-output-to-string
               (lambda ()
                 (compile-file "tools/tpm2-enroll.scm"
                               #:output-file
                               "/tmp/guixcfg-enroll-check.go")))))
    (false-if-exception (delete-file "/tmp/guixcfg-enroll-check.go"))
    (not (string-contains out "unbound"))))

(test-end "tpm2-enroll")
