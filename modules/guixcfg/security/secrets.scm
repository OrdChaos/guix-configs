;;; 声明式 runtime secrets 部署（docs/secrets.md）。
;;;
;;; 模型：
;;;   - ciphertext 随 system closure 进 store（允许）；
;;;     identity 与 plaintext 绝不进 store；
;;;   - boot 时由本服务用 installed stable S
;;;     （/persist/system/keys/age/identity，LUKS 内）一次性解密到
;;;     /run/guixcfg-secrets/（tmpfs），按 scope 分 owner/mode；
;;;   - 缺 identity 或解密失败：服务明确 failed（不询问 master
;;;     password，不打断 boot——登录/消费方会因缺 secret 而失败）。
;;;
;;; scope 语义（仅权限/消费域，同一解密生命周期）：
;;;   install  仅安装/恢复流程消费（luks-recovery、user-password.hash），
;;;            不在 runtime 部署；
;;;   system   → /run/guixcfg-secrets/system/<name>（声明的 owner/mode）；
;;;   user     → /run/guixcfg-secrets/users/<user>/<name>
;;;            （owner=该 user，0600）。
;;;
;;; 用户密码 hash（scope install + account 注入）：ephemeral root 下
;;; @root-template 的 /etc/shadow 在 commit-root 时固化（account
;;; activation 只在首次 boot 运行），install 期注入无法跨 root
;;; rebuild 保留（实测证明）——因此每 boot 由 password-project 服务在
;;; login 前把 hash 注入 ephemeral /etc/shadow。hash 不进 store、不进
;;; argv、不进日志。

(define-module (guixcfg security secrets)
               #:use-module (gnu services)              ; simple-service
               #:use-module (gnu services shepherd)     ; shepherd-service
               #:use-module (gnu packages golang-crypto)  ; age
               #:use-module (guix gexp)
               #:use-module (guix modules)              ; source-module-closure
               #:use-module (guix records)
               #:use-module (ice-9 match)
               #:export (%secrets-runtime-root
                         %secrets-store-subdir
                         secret-decl
                         secret-decl?
                         secret-decl-name
                         secret-decl-scope
                         secret-decl-source
                         secret-decl-target-name
                         secret-decl-owner-user
                         secret-decl-mode
                         runtime-secret-target
                         secrets-deploy-program
                         secrets-deploy-service
                         password-project-program
                         password-project-service
                         %vm-secrets))

;; runtime root（tmpfs，root 0700）。
(define %secrets-runtime-root "/run/guixcfg-secrets")

;; 仓库内 ciphertext 相对根（随 system closure 进 store）。
(define %secrets-store-subdir "secrets")

(define-record-type* <secret-decl> secret-decl make-secret-decl
  secret-decl?
  (name       secret-decl-name)          ; symbol（逻辑名）
  (scope      secret-decl-scope)         ; 'install | 'system | 'user
  (source     secret-decl-source)        ; string：仓库内相对路径（.age）
  (target-name secret-decl-target-name)  ; string：runtime 文件名
  (owner-user secret-decl-owner-user     ; string：owner 用户名
              (default "root"))
  (mode       secret-decl-mode           ; integer
              (default #o400)))

(define (runtime-secret-target decl user)
  "DECL（scope system/user）的 runtime 绝对路径。"
  (match (secret-decl-scope decl)
    ('system
     (string-append %secrets-runtime-root "/system/"
                    (secret-decl-target-name decl)))
    ('user
     (string-append %secrets-runtime-root "/users/" user "/"
                    (secret-decl-target-name decl)))
    (other (error "install scope has no runtime target" other))))

;;; ────────────────────────────────────────────────────────────
;;; 部署程序（boot 时以 root 运行；age 经 -i 文件 identity，密语不经
;;; argv；明文经 -o /run 0600 临时文件 + 原子 rename）。

(define (secrets-deploy-program decls user)
  "生成解密部署所有 runtime secrets（scope system/user）的程序。
USER 是 primary user 名（user scope 的 owner）。ciphertext 经
local-file 进 system closure（允许）；identity 与 plaintext 不进
store。"
  (program-file
   "guixcfg-secrets-deploy"
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils))
         (define runtime-root #$%secrets-runtime-root)
         ;; age 用 closure 内的绝对路径——不依赖服务进程的 PATH
         ;; （shepherd 服务继承 boot 时的环境，PATH 里可能无 age）。
         (define age-bin #$(file-append age "/bin/age"))
         (define identity "/persist/system/keys/age/identity")
         (define (run-age-decrypt cipher out-path uid gid mode)
           ;; 输出先到同目录 .new（0600）再原子 rename——失败不留
           ;; partial plaintext（age 失败时不写输出文件）。
           (let ((tmp (string-append out-path ".new")))
             (mkdir-p (dirname out-path))
             (call-with-output-file tmp (lambda (p) #t))
             (chmod tmp #o600)
             (catch #t
               (lambda ()
                 (invoke age-bin "--decrypt" "-i" identity
                         "-o" tmp cipher)
                 (chmod tmp mode)
                 (chown tmp uid gid)
                 (rename-file tmp out-path))
               (lambda (k . a)
                 (false-if-exception (delete-file tmp))
                 (apply throw k a)))))
         (unless (file-exists? identity)
           (error "stable identity missing; refusing to prompt" identity))
         ;; 目录层级权限（user 要能穿越 root 目录读到自己的 secret）：
         ;;   runtime-root   root 0755（可穿越）
         ;;   system/        root 0700（仅 root）
         ;;   users/         root 0755（可穿越）
         ;;   users/<user>/  owner=<user> 0700（仅该用户）
         (mkdir-p runtime-root)
         (chmod runtime-root #o755)
         (chown runtime-root 0 0)
         (let ((sys-dir (string-append runtime-root "/system"))
               (users-dir (string-append runtime-root "/users")))
           (mkdir-p sys-dir) (chmod sys-dir #o700) (chown sys-dir 0 0)
           (mkdir-p users-dir) (chmod users-dir #o755) (chown users-dir 0 0))
         #$@(map
             (lambda (decl)
               (let* ((source (secret-decl-source decl))  ; local-file
                      (target (runtime-secret-target decl user))
                      (owner (secret-decl-owner-user decl))
                      (mode (secret-decl-mode decl)))
                 #~(begin
                     (let* ((pw (getpw #$owner))
                            (uid (passwd:uid pw))
                            (gid (passwd:gid pw))
                            (parent (dirname #$target)))
                       ;; user scope：users/<user>/ 目录归该用户 0700
                       (mkdir-p parent)
                       (when (string-prefix?
                              (string-append runtime-root "/users/")
                              parent)
                         (chown parent uid gid)
                         (chmod parent #o700))
                       (run-age-decrypt
                        #$(local-file (assume-valid-file-name source))
                        #$target uid gid #$mode)))))
             (filter (lambda (d)
                       (memq (secret-decl-scope d) '(system user)))
                     decls))
         #t))))

(define (secrets-deploy-service decls user)
  "boot 时（file-systems 后、user-processes 前）解密部署 runtime
secrets 的 one-shot 服务。"
  (simple-service 'guixcfg-secrets-deploy shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(guixcfg-secrets-deploy))
                         (requirement '(file-systems))
                         (one-shot? #t)
                         (documentation
                          "Decrypt declarative runtime secrets with the \
installed stable age identity into /run/guixcfg-secrets (tmpfs).")
                         (start #~(lambda ()
                                    (zero? (system*
                                            #$(secrets-deploy-program
                                               decls user)))))
                         (stop #~(const #f))))))

;;; ────────────────────────────────────────────────────────────
;;; 用户密码 hash 注入（install secret 的 account 消费路径）

(define (password-project-program user)
  "生成纯 password projector 程序：/persist/system/accounts/USER/
password.hash → validate → 投影 /etc/shadow → provision
account-state-ready。不调用 age、不读 .age、不访问 stable S、不碰
/run/guixcfg-secrets。任何失败 fail closed：不产空密码用户、不删
原 shadow 条目、不标 ready。"
  (program-file
   "guixcfg-password-project"
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils) (ice-9 rdelim) (srfi srfi-13)
                      (ice-9 regex))
         (define user #$user)
         (define hash-path
           (string-append "/persist/system/accounts/" user
                          "/password.hash"))
         (define (valid-hash? s)
           (and (string-match "^\\$[0-9a-z]+\\$[^:$]+\\$[^: \n]+$" s)
                #t))
         ;; hash 必须在且形态合法（否则 fail closed：不投影、不 ready）。
         (unless (file-exists? hash-path)
           (error "persistent password hash missing" hash-path))
         (let* ((hash (string-trim-right
                       (call-with-input-file hash-path
                         (lambda (p) (read-string p)))
                       #\newline))
                (shadow (call-with-input-file "/etc/shadow"
                          (lambda (p) (read-string p))))
                (lines (string-split shadow #\newline)))
           (unless (valid-hash? hash)
             (error "persistent password hash malformed" user))
           (unless (any (lambda (line)
                          (let ((fields (string-split line #\:)))
                            (and (pair? fields)
                                 (string=? (car fields) user))))
                        lines)
             (error "target user missing from /etc/shadow" user))
           (let ((out-lines
                  (map (lambda (line)
                         (let ((fields (string-split line #\:)))
                           (if (and (pair? fields)
                                    (string=? (car fields) user))
                               (string-join (cons hash (cdr fields)) ":")
                               line)))
                       lines))
                 (new "/etc/.shadow.guixcfg-new"))
             ;; 原子投影：临时文件 0600 root → rename（失败保留原
             ;; shadow——不删条目、不产空密码用户）。
             (call-with-output-file new
               (lambda (p) (display (string-join out-lines "\n") p)))
             (chmod new #o600)
             (chown new 0 0)
             (rename-file new "/etc/shadow")
             #t))))))

(define (password-project-service user)
  "boot 时把 persistent password hash 投影进 ephemeral /etc/shadow 的
one-shot 服务；成功完成才 provision account-state-ready（不是
脚本启动了，而是投影已完成）。"
  (simple-service 'guixcfg-password-project shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(guixcfg-password-project
                                      account-state-ready))
                         (requirement '(file-systems user-homes))
                         (one-shot? #t)
                         (documentation
                          "Project the persistent login credential hash \
into the ephemeral /etc/shadow at boot; provides account-state-ready.")
                         (start #~(lambda ()
                                    (zero? (system*
                                            #$(password-project-program
                                               user)))))
                         (stop #~(const #f))))))

;;; ────────────────────────────────────────────────────────────
;;; VM 当前声明的 runtime secrets（测试用 sentinel，无真实凭据）。

(define %vm-secrets
  (list (secret-decl
         (name 'test-system)
         (scope 'system)
         (source "secrets/system/test-system.age")
         (target-name "test-system")
         (owner-user "root")
         (mode #o400))
        (secret-decl
         (name 'test-user)
         (scope 'user)
         (source "secrets/user/test-user.age")
         (target-name "test-user")
         (owner-user "user")
         (mode #o600))))
