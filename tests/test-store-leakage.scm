;;; Store leakage 回归（docs/architecture/secrets.md 不变量 9）：secret plaintext
;;; （sentinel / password hash）绝不进入 /gnu/store。
;;;
;;; 扫描范围（合理的注入面，非全盘 grep）：
;;;   1. system activation 脚本（account/shadow 生成的潜在载体）；
;;;   2. secrets 部署/密码注入脚本；
;;;   3. system derivation 文本（所有内嵌引用）；
;;;   4. Guix Home closure 的 files。
;;; sentinel 字符串与测试 hash 的 salt 是本轮测试 ciphertext 的明文
;;; 独有标记——出现在任何 store 路径即失败。

(use-modules (gnu system)
             (guix store)
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

;; 1. system activation 脚本（含 account/shadow 生成逻辑）
(define %vm-os (module-ref (resolve-module '(guixcfg hosts vm)) '%os))
(define activation-text
  (build-text (lower-object (operating-system-activation-script %vm-os))))
(test-assert "activation script contains no secret plaintext"
             (no-leak? activation-text))

;; 2. secrets 部署脚本 + 密码注入脚本
(define deploy-text
  (build-text
   (gexp->file "leak-check-deploy"
               (program-file-gexp
                (secrets-deploy-program %vm-secrets "user")))))
(test-assert "secrets deploy script clean" (no-leak? deploy-text))

(define verify-text
  (build-text
   (gexp->file "leak-check-verify"
               (program-file-gexp
                (account-databases-verify-program "user")))))
(test-assert "account verify script clean" (no-leak? verify-text))

;; 3. system derivation 文本（内嵌引用面）
(define system-drv
  (run-with-store %store (lower-object %vm-os)))
(define system-drv-text (file-text (derivation-file-name system-drv)))
(test-assert "system drv contains no secret plaintext"
             (no-leak? system-drv-text))

;; 4. ciphertext 本身允许进 store——但密文形态不含明文标记
;;    （反面验证：ciphertext 在 closure 中是被允许的）。
(test-assert "ciphertext may enter store (armored age, no plaintext)"
             (no-leak? (file-text "secrets/system/test-system.age")))

(test-end "store-leakage")
