;;; Noctalia

(define-module (guixcfg apps noctalia-git definition)
               #:use-module (noctalia)                 ; noctalia-git
               #:use-module (guix gexp)                ; local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)       ; application
               #:export (%app))

(define %app
  (application
   (name 'app)                       ; symbol：registry 里唯一
   (home-packages (list noctalia-git))     ; 用户 profile 包（service 自动贡献的不要重复）
   ;; (home-services (list ...))     ; home service 实例（官方 home-*-service-type）
   ;; (system-services (list ...))   ; system service（仅确有必要；greetd/elogind/
   ;;                                 ; accounts/SSH host keys/readiness/TPM/UKI/
   ;;                                 ; Secure Boot 等 core infrastructure 不迁进 apps）
   ;; (persistence (list ...))       ; <application-persistence-rule>（bind-only）
   ;; (secrets (list ...))           ; <secret-decl>（source = 本目录 secrets/ 的
   ;;                                 ; file-like，如 (local-file "secrets/x.age")）
   ))
