;;; Runtime secrets 部署测试：secret 声明结构、scope→路径映射、
;;; 服务构造（shepherd one-shot、file-systems 依赖）、ciphertext 进
;;; closure 而 plaintext 不进。
;;; 部署行为本身在 VM 集成验证（sentinel E2E）。

(use-modules (guix store)
             (guix monads)
             (guix derivations)          ; build-derivations
             (gnu services)
             (gnu services shepherd)
             (guix gexp)
             (guixcfg security secrets)
             (guixcfg hosts vm)            ; %vm-test-secrets（VM 测试机 sentinel）
             (guixcfg users user)         ; %primary-user（owner 权威来源）
             (guixcfg utils repository-source) ; 仓库根唯一 resolver
             (guixcfg apps model)          ; applications-secrets（聚合，无 system consumer）
             (guixcfg apps registry)       ; %applications
             (guixcfg system accounts)
             (guixcfg system readiness)   ; %interactive-session-requirements
             (ice-9 rdelim)               ; read-string
             (srfi srfi-1)
             (srfi srfi-13)               ; string-suffix?
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "secrets")

;; 声明结构（sentinel 由 VM 装配点声明，generic 机制不含 inventory）
(test-assert "generic secrets module does not own the VM sentinel inventory"
             (not (module-defined? (resolve-module '(guixcfg security secrets))
                                   '%vm-test-secrets)))
(define sys-secret (car %vm-test-secrets))
(define usr-secret (cadr %vm-test-secrets))

(test-equal "system secret scope" 'system (secret-decl-scope sys-secret))
(test-equal "user secret scope" 'user (secret-decl-scope usr-secret))
(test-equal "system secret mode" #o400 (secret-decl-mode sys-secret))
(test-equal "user secret mode" #o600 (secret-decl-mode usr-secret))
(test-equal "user secret owner derives from %primary-user"
            (user-profile-name %primary-user)
            (secret-decl-owner-user usr-secret))

;; secret-decl-source 是 file-like（caller 解析；generic 不知 repository
;; layout）且解析到仓库中的 ciphertext
(test-assert "secret sources are file-like local-file objects"
             (every (lambda (d) (local-file? (secret-decl-source d)))
                    %vm-test-secrets))
(test-assert "secret sources resolve to existing ciphertext files"
             (every (lambda (d)
                      (file-exists? (local-file-absolute-file-name
                                     (secret-decl-source d))))
                    %vm-test-secrets))

;; repository-source 唯一 resolver（AGENT.md：top-level secrets 引用
;; 只能走它；source-relative，不依赖 shell CWD）
(test-assert "repository-file resolves to repo-root ciphertext"
             (let ((lf (repository-file "tests/fixtures/secrets/test-system.age")))
               (and (local-file? lf)
                    (string-suffix? "/tests/fixtures/secrets/test-system.age"
                                    (local-file-absolute-file-name lf))
                    (file-exists? (local-file-absolute-file-name lf)))))
;; ── Secret ownership（repository ownership ≠ deployment target）──
;; VM 测试 sentinel：密文归 tests/fixtures/secrets/（测试域），由 VM
;; 装配点声明；test-user 的 deployment target 是 user（scope 'user），
;; 但仓库侧不存在 host-owned secret 层。
(test-assert "vm test sentinel ciphertexts live under tests/fixtures/secrets/"
             (every (lambda (d)
                      (string-contains
                       (local-file-absolute-file-name (secret-decl-source d))
                       "/tests/fixtures/secrets/"))
                    %vm-test-secrets))

(test-assert "user-target sentinel is declared by the VM assembly"
             (let ((lf (secret-decl-source usr-secret)))
               (and (eq? 'user (secret-decl-scope usr-secret))
                    (string-contains
                     (local-file-absolute-file-name lf)
                     "/tests/fixtures/secrets/"))))

(test-assert "no host-owned secret layer remains (no secrets/hosts)"
             (every (lambda (d)
                      (not (string-contains
                            (local-file-absolute-file-name (secret-decl-source d))
                            "/secrets/hosts/")))
                    %vm-test-secrets))

(test-assert "application secrets are all ordinary (never login-critical)"
             (every (lambda (d) (eq? 'ordinary (secret-decl-domain d)))
                    (applications-secrets %applications)))

;; ── Readiness domain（login-critical / ordinary；显式必填）────
(test-equal "vm system fixture is login-critical"
            'login-critical (secret-decl-domain sys-secret))
(test-equal "vm user fixture is login-critical"
            'login-critical (secret-decl-domain usr-secret))
(test-assert "unknown domain is rejected by partition helpers"
             (catch #t
               (lambda ()
                 (login-critical-secrets
                  (list (secret-decl
                         (name 'bad) (scope 'system) (domain 'bogus)
                         (source (local-file "x.age")) (target-name "x"))))
                 #f)
               (lambda (k . a) #t)))
(test-equal "login-critical-secrets partitions"
            '(crit)
            (map secret-decl-name
                 (login-critical-secrets
                  (list (secret-decl
                         (name 'crit) (scope 'system) (domain 'login-critical)
                         (source (local-file "x.age")) (target-name "x"))
                        (secret-decl
                         (name 'ord) (scope 'user) (domain 'ordinary)
                         (source (local-file "y.age")) (target-name "y"))))))
(test-equal "ordinary-secrets partitions"
            '(ord)
            (map secret-decl-name
                 (ordinary-secrets
                  (list (secret-decl
                         (name 'crit) (scope 'system) (domain 'login-critical)
                         (source (local-file "x.age")) (target-name "x"))
                        (secret-decl
                         (name 'ord) (scope 'user) (domain 'ordinary)
                         (source (local-file "y.age")) (target-name "y"))))))
;; domain 决定 runtime root：ordinary 走独立 atomic root
(test-equal "ordinary secret targets the ordinary root"
            "/run/guixcfg-secrets-ordinary/users/user/ord"
            (runtime-secret-target
             (secret-decl (name 'ord) (scope 'user) (domain 'ordinary)
                          (source (local-file "y.age")) (target-name "ord"))
             "user"))
(test-equal "critical secret keeps the historical root"
            "/run/guixcfg-secrets/system/crit"
            (runtime-secret-target
             (secret-decl (name 'crit) (scope 'system) (domain 'login-critical)
                          (source (local-file "x.age")) (target-name "crit"))
             "user"))
;; 两个 domain 的 atomic publication roots 互不冲突
(test-assert "critical and ordinary roots are distinct"
             (and (not (string=? %secrets-runtime-root
                                 %secrets-ordinary-runtime-root))
                  (not (string=? %secrets-store-root
                                 %secrets-ordinary-store-root))))

;; ── host assembly / wiring（A7-8/9/10）─────────────────────
(test-assert "host assembly consumes applications-secrets (partitioned by domain)"
             ;; composition 拆分为 host inventory（vm.scm：secret 集合
             ;; 含 applications-secrets）与共享组装算法（common.scm：
             ;; login-critical / ordinary domain 分区）。
             (let ((s (call-with-input-file "modules/guixcfg/hosts/vm.scm"
                                            (lambda (p) (read-string p))))
                   (c (call-with-input-file "modules/guixcfg/hosts/common.scm"
                                            (lambda (p) (read-string p)))))
               (and (string-contains s "applications-secrets %applications")
                    (string-contains c "login-critical-secrets")
                    (string-contains c "ordinary-secrets"))))

(test-assert "ordinary deploy service with empty app-secret set is legal"
             (let ((svcs (service-value
                          (secrets-ordinary-deploy-service
                           (ordinary-secrets
                            (append %vm-test-secrets
                                    (applications-secrets %applications)))
                           "user"))))
               (and (pair? svcs)
                    (shepherd-service-one-shot? (car svcs))
                    (member 'ordinary-secrets-ready
                            (shepherd-service-provision (car svcs))))))

(test-assert "login gate does not depend on ordinary-secrets-ready"
             (not (memq 'ordinary-secrets-ready
                        %interactive-session-requirements)))

(test-assert "generic secrets mechanism ignores app/VM inventory"
             (let ((s (call-with-input-file "modules/guixcfg/security/secrets.scm"
                                            (lambda (p) (read-string p)))))
               (and (not (string-contains s "guixcfg apps"))
                    (not (string-contains s "hosts/vm")))))

(test-assert "repository-file rejects unsafe relative paths"
             (every (lambda (p)
                      (catch #t
                        (lambda () (repository-file p) #f)
                        (lambda (k . a) #t)))
                    '("" "/abs" "a/../b" ".." "a/..")))
(test-assert "repository-file tolerates ./ prefix (normalized)"
             (let ((lf (repository-file "./tests/fixtures/secrets/test-system.age")))
               (and (local-file? lf)
                    (string-suffix? "/tests/fixtures/secrets/test-system.age"
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
                               (domain 'login-critical)
                               (source (local-file "tests/fixtures/secrets/x.age"))
                               (target-name "x"))
                  "user")
                 #f)
               (lambda (k . a) #t)))

;; 服务构造：one-shot、file-systems 依赖、provision
(define deploy-shepherd
  (car (service-value (secrets-deploy-service %vm-test-secrets "user"))))
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
                 (secrets-deploy-program %vm-test-secrets "user"))))
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
                    ;; 读 persistent verifier 根（%account-credentials-dir
                    ;; 收敛后字面量拆为 "/persist/system/accounts" + "/"
                    ;; ——断言语义根即可，不依赖拼写形态）。
                    (string-contains t "/persist/system/accounts"))))

(test-end "secrets")
