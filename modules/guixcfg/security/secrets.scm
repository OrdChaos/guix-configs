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
;;; rebuild 保留（实测证明）——因此每 boot 由 password-inject 服务在
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
                         password-inject-program
                         password-inject-service
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

(define (password-inject-program user source)
  "生成把 user-password.hash.age 的 hash 注入 /etc/shadow 的程序：
  读 shadow、替换 USER 行的 password 字段、原子写回（保留其它字段）。
  SOURCE 是仓库内相对路径字符串；ciphertext 经 local-file 进 closure
  （assume-valid-file-name：从仓库根 reconfigure/build 时按 cwd 解析）；
  hash 只在内存与 ephemeral /etc/shadow 间存在。"
  (program-file
   "guixcfg-password-inject"
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils) (ice-9 rdelim) (srfi srfi-13))
         (define age-bin #$(file-append age "/bin/age"))
         (define identity "/persist/system/keys/age/identity")
         (define cipher #$(local-file (assume-valid-file-name source)))
         (define user #$user)
         (unless (file-exists? identity)
           (error "stable identity missing; refusing to prompt" identity))
         (let ((tmp (string-append "/run/guixcfg-secrets/.pw-"
                                   (number->string (getpid)))))
           ;; 只确保目录存在；权限层级由 guixcfg-secrets-deploy 负责
           ;; （runtime root 0755 可穿越）——这里不动目录权限，避免
           ;; 两个服务的启动顺序影响最终权限。
           (mkdir-p "/run/guixcfg-secrets")
           (dynamic-wind
             (lambda ()
               (call-with-output-file tmp (lambda (p) #t))
               (chmod tmp #o600))
             (lambda ()
               (invoke age-bin "--decrypt" "-i" identity "-o" tmp cipher)
               (let* ((hash (string-trim-both
                             (call-with-input-file tmp
                               (lambda (p) (read-string p)))))
                      (shadow (call-with-input-file "/etc/shadow"
                                (lambda (p) (read-string p))))
                      (lines (string-split shadow #\newline))
                      (out-lines
                       (map (lambda (line)
                              (let ((fields (string-split line #\:)))
                                (if (and (pair? fields)
                                         (string=? (car fields) user))
                                    (string-join
                                     (cons hash (cdr fields)) ":")
                                    line)))
                            lines)))
                 (unless (any (lambda (line)
                                (let ((fields (string-split line #\:)))
                                  (and (pair? fields)
                                       (string=? (car fields) user))))
                              lines)
                   (error "user entry not found in /etc/shadow" user))
                 (let ((new "/etc/.shadow.guixcfg-new"))
                   (call-with-output-file new
                     (lambda (p)
                       (display (string-join out-lines "\n") p)))
                   (chmod new #o600)
                   (chown new 0 0)
                   (rename-file new "/etc/shadow"))))
             (lambda ()
               (false-if-exception (delete-file tmp))))
           #t)))))


(define (password-inject-service user source)
  "boot 时把 install secret 中的用户密码 hash 注入 ephemeral
/etc/shadow 的 one-shot 服务（account activation 之后、login 之前）。
SOURCE 是仓库内相对路径字符串（ciphertext 随 closure 进 store）。"
  (simple-service 'guixcfg-password-inject shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(guixcfg-password-inject))
                         (requirement '(file-systems user-homes))
                         (one-shot? #t)
                         (documentation
                          "Inject the declarative user password hash \
(install secret) into the ephemeral /etc/shadow at boot.")
                         (start #~(lambda ()
                                    (zero? (system*
                                            #$(password-inject-program
                                               user source)))))
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
