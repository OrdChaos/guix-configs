;;; Store leakage 回归（docs/architecture/secrets.md 不变量 9）：secret plaintext
;;; （sentinel / password hash）绝不进入 /gnu/store。
;;;
;;; 扫描范围（合理的注入面，非全盘 grep）：
;;;   1. synthetic secrets deployment script；
;;;   2. account verification script；
;;;   3. tracked ciphertext shape。
;;; sentinel 字符串与测试 hash 的 salt 是本轮测试 ciphertext 的明文
;;; 独有标记——出现在任何 store 路径即失败。

(use-modules (guix store)
             (guix monads)
             (guix derivations)
             (guix gexp)
             (guixcfg security secrets)
             (guixcfg system accounts)
             (ice-9 rdelim)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %store (open-connection))

;; 本轮测试明文标记（secret 内容本身，不出现在任何 store 产物中）
(define %sentinel-system "GUIXCFG_SECRET_SENTINEL_SYSTEM_9f4e2b1a")
(define %sentinel-user "GUIXCFG_SECRET_SENTINEL_USER_7c8d3e5f")
(define %hash-marker "$6$MBShtaT")   ; user-password.hash 的 salt 前缀

(define (file-text path)
  (call-with-input-file path (lambda (p) (read-string p))))

(define (build-text mval)
  (let ((drv (run-with-store %store mval)))
    (build-derivations %store (list drv))
    (file-text (derivation->output-path drv))))

(define (no-leak? text)
  (and (not (string-contains text %sentinel-system))
       (not (string-contains text %sentinel-user))
       (not (string-contains text %hash-marker))))

(test-begin "store-leakage")

;; Synthetic declarations keep this mandatory check independent of full OS,
;; applications, and expensive kernel derivations.
(define %test-secrets
  (list (secret-decl
         (name 'store-leakage-sentinel)
         (scope 'system)
         (domain 'login-critical)
         (source (local-file "tests/fixtures/secrets/test-system.age"))
         (target-name "store-leakage-sentinel"))))

(define deploy-text
  (build-text
   (gexp->file "leak-check-deploy"
               (program-file-gexp
                (secrets-deploy-program %test-secrets "user")))))
(test-assert "secrets deploy script clean" (no-leak? deploy-text))

(define verify-text
  (build-text
   (gexp->file "leak-check-verify"
               (program-file-gexp
                (account-databases-verify-program "user")))))
(test-assert "account verify script clean" (no-leak? verify-text))

;; Ciphertext itself may enter the store, but never its plaintext.
;;    （反面验证：ciphertext 在 closure 中是被允许的）。
(test-assert "ciphertext may enter store (armored age, no plaintext)"
             (no-leak? (file-text "tests/fixtures/secrets/test-system.age")))

(test-end "store-leakage")
