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
             (guixcfg hosts vm-secrets)   ; %vm-secrets（host-owned inventory）
             (guixcfg utils repository-source) ; 仓库根唯一 resolver
             (guixcfg system accounts)
             (srfi srfi-1)
             (srfi srfi-13)               ; string-suffix?
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "secrets")

;; 声明结构（inventory 在 host-owned 模块，generic 机制不含 %vm-secrets）
(test-assert "generic secrets module no longer exports %vm-secrets"
             (not (module-defined? (resolve-module '(guixcfg security secrets))
                                   '%vm-secrets)))
(define sys-secret (car %vm-secrets))
(define usr-secret (cadr %vm-secrets))

(test-equal "system secret scope" 'system (secret-decl-scope sys-secret))
(test-equal "user secret scope" 'user (secret-decl-scope usr-secret))
(test-equal "system secret mode" #o400 (secret-decl-mode sys-secret))
(test-equal "user secret mode" #o600 (secret-decl-mode usr-secret))
(test-equal "user secret owner" "user" (secret-decl-owner-user usr-secret))

;; secret-decl-source 是 file-like（caller 解析；generic 不知 repository
;; layout）且解析到仓库中的 ciphertext
(test-assert "secret sources are file-like local-file objects"
             (every (lambda (d) (local-file? (secret-decl-source d)))
                    %vm-secrets))
(test-assert "secret sources resolve to existing ciphertext files"
             (every (lambda (d)
                      (file-exists? (local-file-absolute-file-name
                                     (secret-decl-source d))))
                    %vm-secrets))

;; repository-source 唯一 resolver（AGENT.md：top-level secrets 引用
;; 只能走它；source-relative，不依赖 shell CWD）
(test-assert "repository-file resolves to repo-root ciphertext"
             (let ((lf (repository-file "secrets/system/test-system.age")))
               (and (local-file? lf)
                    (string-suffix? "/secrets/system/test-system.age"
                                    (local-file-absolute-file-name lf))
                    (file-exists? (local-file-absolute-file-name lf)))))
(test-assert "repository-file rejects unsafe relative paths"
             (every (lambda (p)
                      (catch #t
                        (lambda () (repository-file p) #f)
                        (lambda (k . a) #t)))
                    '("" "/abs" "a/../b" ".." "a/..")))
(test-assert "repository-file tolerates ./ prefix (normalized)"
             (let ((lf (repository-file "./secrets/system/test-system.age")))
               (and (local-file? lf)
                    (string-suffix? "/secrets/system/test-system.age"
                                    (local-file-absolute-file-name lf))
                    (file-exists? (local-file-absolute-file-name lf)))))

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
                               (source (local-file "secrets/install/x.age"))
                               (target-name "x"))
                  "user")
                 #f)
               (lambda (k . a) #t)))

;; 服务构造：one-shot、file-systems 依赖、provision
(define deploy-shepherd
  (car (service-value (secrets-deploy-service %vm-secrets "user"))))
(test-assert "deploy service one-shot"
             (shepherd-service-one-shot? deploy-shepherd))
(test-assert "deploy service requires persistent-state-ready"
             (member 'persistent-state-ready
                     (shepherd-service-requirement deploy-shepherd)))
(test-assert "deploy service provides interactive-secrets-ready"
             (member 'interactive-secrets-ready
                     (shepherd-service-provision deploy-shepherd)))
(test-assert "deploy provision"
             (member 'guixcfg-secrets-deploy
                     (shepherd-service-provision deploy-shepherd)))

(define project-shepherd
  (car (service-value (account-databases-verify-service "user"))))
(test-assert "verify service one-shot"
             (shepherd-service-one-shot? project-shepherd))
(test-assert "verify service after user-homes (account activation done)"
             (member 'user-homes (shepherd-service-requirement project-shepherd)))
(test-assert "verify requires persistent-state-ready"
             (member 'persistent-state-ready
                     (shepherd-service-requirement project-shepherd)))
(test-assert "verify provides account-state-ready"
             (member 'account-state-ready
                     (shepherd-service-provision project-shepherd)))

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
(test-assert "verify script contains no password hash"
             (not (string-contains
                   (call-with-input-file
                    (build-script
                     (gexp->file "guixcfg-account-verify-test"
                                 (program-file-gexp
                                  (account-databases-verify-program "user"))))
                    (lambda (p) (read-string p)))
                   "$6$")))
;; verify 是纯只读验证——绝不调 age/读 .age/访问 stable S、绝不写 shadow
(test-assert "verify script is read-only, no age/runtime secrets"
             (let ((t (call-with-input-file
                       (build-script
                        (gexp->file "guixcfg-account-verify-pure-test"
                                    (program-file-gexp
                                     (account-databases-verify-program "user"))))
                       (lambda (p) (read-string p)))))
               (and (not (string-contains t "age --decrypt"))
                    (not (string-contains t "/persist/system/keys/age"))
                    (not (string-contains t "/run/guixcfg-secrets"))
                    (not (string-contains t "rename-file"))
                    (string-contains t "/persist/system/accounts/"))))

(test-end "secrets")
