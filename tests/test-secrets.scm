;;; Runtime secrets 部署测试：secret 声明结构、scope→路径映射、
;;; 服务构造（shepherd one-shot、file-systems 依赖）、ciphertext 进
;;; closure 而 plaintext 不进。
;;; 部署行为本身在 VM 集成验证（sentinel E2E）。

(use-modules (guix store)
             (guix monads)
             (gnu services)
             (gnu services shepherd)
             (guix gexp)
             (guixcfg security secrets)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "secrets")

;; 声明结构
(define sys-secret (car %vm-secrets))
(define usr-secret (cadr %vm-secrets))

(test-equal "system secret scope" 'system (secret-decl-scope sys-secret))
(test-equal "user secret scope" 'user (secret-decl-scope usr-secret))
(test-equal "system secret mode" #o400 (secret-decl-mode sys-secret))
(test-equal "user secret mode" #o600 (secret-decl-mode usr-secret))
(test-equal "user secret owner" "user" (secret-decl-owner-user usr-secret))

;; scope → runtime 路径映射
(test-equal "system secret target"
  "/run/guixcfg-secrets/system/test-system"
  (runtime-secret-target sys-secret "user"))
(test-equal "user secret target"
  "/run/guixcfg-secrets/users/user/test-user"
  (runtime-secret-target usr-secret "user"))
(test-assert "install scope has no runtime target"
  (catch #t
    (lambda ()
      (runtime-secret-target
       (secret-decl (name 'x) (scope 'install)
                    (source "secrets/install/x.age")
                    (target-name "x"))
       "user")
      #f)
    (lambda (k . a) #t)))

;; 服务构造：one-shot、file-systems 依赖、provision
(define deploy-shepherd
  (car (service-value (secrets-deploy-service %vm-secrets "user"))))
(test-assert "deploy service one-shot"
  (shepherd-service-one-shot? deploy-shepherd))
(test-assert "deploy service requires file-systems"
  (member 'file-systems (shepherd-service-requirement deploy-shepherd)))
(test-assert "deploy provision"
  (member 'guixcfg-secrets-deploy
          (shepherd-service-provision deploy-shepherd)))

(define inject-shepherd
  (car (service-value (password-inject-service
                       "user" "secrets/install/user-password.hash.age"))))
(test-assert "inject service one-shot"
  (shepherd-service-one-shot? inject-shepherd))
(test-assert "inject service after user-homes (account activation done)"
  (member 'user-homes (shepherd-service-requirement inject-shepherd)))

;; ciphertext 进 closure（local-file 引用）；identity 路径在运行期
;; 程序中出现但**不含任何明文**——构建最终脚本验证文本不含
;; sentinel/hash（store-leakage 的最内层断言）。
(define %store (open-connection))

(define (build-script mval)
  "构建 monadic gexp->file 结果并返回输出文件路径。"
  (let ((drv (run-with-store %store mval)))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define deploy-script
  (call-with-input-file
      (build-script
       (gexp->file "guixcfg-secrets-deploy-test"
                   (program-file-gexp
                    (secrets-deploy-program %vm-secrets "user"))))
    (lambda (p) (read-string p))))

(test-assert "deploy script runs age with installed identity"
  (and (string-contains deploy-script "/persist/system/keys/age/identity")
       (string-contains deploy-script "--decrypt")))
(test-assert "deploy script contains no plaintext sentinel"
  (not (string-contains deploy-script "GUIXCFG_SECRET_SENTINEL")))
(test-assert "inject script contains no password hash"
  (not (string-contains
        (call-with-input-file
            (build-script
             (gexp->file "guixcfg-password-inject-test"
                         (program-file-gexp
                          (password-inject-program
                           "user" "secrets/install/user-password.hash.age"))))
          (lambda (p) (read-string p)))
        "$6$")))

(test-end "secrets")
