;;; 声明式 runtime secrets 部署（docs/architecture/secrets.md）。
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
;;; 用户密码 hash（scope install 的 provisioning source）：hash 由安装
;;; 流程物化为 persistent verifier
;;; （/persist/system/accounts/<user>/password.hash，root 0600），并由
;;; account databases 投影（guixcfg/system/accounts.scm——唯一 writer）
;;; 在每 boot 内联进 ephemeral /etc/shadow。本模块不再包含任何
;;; /etc/shadow writer。hash 不进 store、不进 argv、不进日志。

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
  "生成 runtime secrets 事务性发布程序（generation publication，
docs/architecture/secrets.md（Runtime secrets））：
  /run/guixcfg-secrets.d/<N>/     root 0711（可穿越不可列）
    system/                        root 0700
    users/                         root 0711
    users/<user>/                  owner=<user> 0700
  /run/guixcfg-secrets -> secrets.d/<current>（symlink 原子切换）

  流程：NEW.tmp 建好最终权限 → 解密全部 secret（.new 0600 内）→
  owner/mode → 任一失败删 NEW.tmp（当前代不动）→ rename → 原子切换
  current symlink → 清理旧代。consumer 永远看到完整旧代或完整新代。
  本服务是 /run/guixcfg-secrets* 的唯一 owner（mkdir/chmod/chown/
  发布/清理/代际切换全在这里；password projector 不碰它）。"
  (program-file
   "guixcfg-secrets-deploy"
   ;; closure seeds 与 runtime use-modules 一一对应：srfi-1（filter-map）
   ;; 显式列出，不依赖 guix build utils 的传递依赖碰巧带入。
   (with-imported-modules (source-module-closure '((guix build utils)
                                                   (srfi srfi-1)))
                          #~(begin
                             (use-modules (guix build utils) (ice-9 ftw) (ice-9 regex)
                                          (srfi srfi-1))
                             ;; age 用 closure 内的绝对路径——不依赖服务进程的 PATH
                             ;; （shepherd 服务继承 boot 时的环境，PATH 里可能无 age）。
                             (define age-bin #$(file-append age "/bin/age"))
                             (define identity "/persist/system/keys/age/identity")
                             (define store-dir "/run/guixcfg-secrets.d")
                             (define current-link #$%secrets-runtime-root)
                             
                             (define (decrypt-into cipher out-path uid gid mode)
                               ;; 输出先到同目录 .new（0600）再原子 rename——age 失败不写
                               ;; 输出文件，不留 partial plaintext。
                               (let ((tmp (string-append out-path ".new")))
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
                             
                             (define (next-generation)
                               ;; 现有最大数字目录 + 1（boot 时从 1 开始）。
                               (let* ((ents (if (file-exists? store-dir)
                                              (scandir store-dir)
                                              '()))
                                      (nums (filter-map
                                             (lambda (e)
                                               (let ((m (string-match "^[0-9]+$" e)))
                                                 (and m (string->number e))))
                                             ents)))
                                 (if (null? nums) 1 (+ 1 (apply max nums)))))
                             
                             (define (rm-rf path)
                               (when (file-exists? path)
                                 (delete-file-recursively path)))
                             
                             (unless (file-exists? identity)
                               (error "stable identity missing; refusing to prompt" identity))
                             
                             (let* ((n (next-generation))
                                    (tmp-dir (string-append store-dir "/." (number->string n)
                                                            ".tmp"))
                                    (new-dir (string-append store-dir "/" (number->string n))))
                               (mkdir-p store-dir)
                               (chmod store-dir #o711)
                               (chown store-dir 0 0)
                               (catch #t
                                 (lambda ()
                                   ;; 1. NEW.tmp：最终目录权限先就位
                                   (mkdir-p tmp-dir)
                                   (chmod tmp-dir #o711)
                                   (chown tmp-dir 0 0)
                                   (let ((sys-dir (string-append tmp-dir "/system"))
                                         (users-dir (string-append tmp-dir "/users")))
                                     (mkdir-p sys-dir) (chmod sys-dir #o700) (chown sys-dir 0 0)
                                     (mkdir-p users-dir) (chmod users-dir #o711)
                                     (chown users-dir 0 0))
                                   ;; 2. 解密全部 secret（含 owner/mode）
                                   #$@(map
                                       (lambda (decl)
                                         (let* ((source (secret-decl-source decl))
                                                (scope (secret-decl-scope decl))
                                                (owner (secret-decl-owner-user decl))
                                                (mode (secret-decl-mode decl))
                                                (rel-target
                                                 (match scope
                                                        ('system (string-append
                                                                  "system/"
                                                                  (secret-decl-target-name decl)))
                                                        ('user (string-append
                                                                "users/" user "/"
                                                                (secret-decl-target-name decl))))))
                                           #~(begin
                                              (let* ((pw (getpw #$owner))
                                                     (uid (passwd:uid pw))
                                                     (gid (passwd:gid pw))
                                                     (parent (dirname
                                                              (string-append tmp-dir "/"
                                                                             #$rel-target))))
                                                (mkdir-p parent)
                                                ;; users/<user>/ 归该用户 0700
                                                (when (string-prefix?
                                                       (string-append tmp-dir "/users/")
                                                       parent)
                                                  (chown parent uid gid)
                                                  (chmod parent #o700))
                                                (decrypt-into
                                                 #$(local-file (assume-valid-file-name source))
                                                 (string-append tmp-dir "/" #$rel-target)
                                                 uid gid #$mode)))))
                                       (filter (lambda (d)
                                                 (memq (secret-decl-scope d) '(system user)))
                                               decls))
                                   ;; 3. 提交：rename NEW.tmp → NEW
                                   (rename-file tmp-dir new-dir)
                                   ;; 4. 原子切换 current symlink（临时 symlink + rename）
                                   (let ((pivot (string-append current-link ".new")))
                                     (false-if-exception (delete-file pivot))
                                     (symlink new-dir pivot)
                                     (rename-file pivot current-link))
                                   ;; 5. 清理旧代（保留当前代）
                                   (for-each
                                    (lambda (e)
                                      (let ((p (string-append store-dir "/" e)))
                                        (when (and (string-match "^[0-9]+$" e)
                                                   (not (string=? e (number->string n))))
                                          (rm-rf p))))
                                    (scandir store-dir))
                                   #t)
                                 (lambda (k . a)
                                   ;; 任一失败：删 NEW.tmp，当前代不动
                                   (rm-rf tmp-dir)
                                   (apply throw k a))))))))

(define (secrets-deploy-service decls user)
  "boot 时（file-systems 后、user-processes 前）解密部署 runtime
secrets 的 one-shot 服务。"
  (simple-service 'guixcfg-secrets-deploy shepherd-root-service-type
                  (list (shepherd-service
                         ;; 发布完成 = interactive-critical secrets 全部
                         ;; 就位（当前无 login-critical 普通 secret——
                         ;; 轻量 barrier，保留抽象）。
                         (provision '(guixcfg-secrets-deploy
                                      interactive-secrets-ready))
                         (requirement '(persistent-state-ready))
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
