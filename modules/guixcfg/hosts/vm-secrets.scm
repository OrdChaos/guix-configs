;;; VM host 的 secret inventory（host-owned configuration）。
;;;
;;; 所有权边界（docs/architecture/secrets.md）：generic runtime
;;; secret publisher 在 (guixcfg security secrets)——本模块只声明
;;; VM 这台机器要部署哪些 secret；generic mechanism 不知道 VM。
;;;
;;; 当前是测试 sentinel（无真实凭据）。ciphertext 走
;;; (guixcfg utils repository-source) 的唯一 resolver 解析为
;;; file-like（top-level secrets/ 属于集中式 system/host 域，见
;;; AGENT.md §Application layer——单一 app owner 的密文才 colocate
;;; 到 apps/<app>/secrets/）。

(define-module (guixcfg hosts vm-secrets)
               #:use-module (guix records)
               #:use-module (guixcfg security secrets)     ; secret-decl
               #:use-module (guixcfg utils repository-source) ; repository-file
               #:export (%vm-secrets))

(define %vm-secrets
  (list (secret-decl
         (name 'test-system)
         (scope 'system)
         (source (repository-file "secrets/hosts/vm/test-system.age"))
         (target-name "test-system")
         (owner-user "root")
         (mode #o400))
        (secret-decl
         (name 'test-user)
         (scope 'user)
         (source (repository-file "secrets/hosts/vm/test-user.age"))
         (target-name "test-user")
         (owner-user "user")
         (mode #o600))))
