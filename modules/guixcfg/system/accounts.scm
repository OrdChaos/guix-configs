;;; Account databases projection（docs/system-home-boundaries.md
;;; System-state phase / account projection）。
;;;
;;; 背景：上游 (gnu build activation)::activate-users+groups 把数据库
;;; 写入（user+group-databases + write-group/write-passwd/write-shadow，
;;; 全部纯 Scheme，来自 (gnu build accounts)）包在 with-file-lock
;;; %password-lock-file 里。该锁走 (guix build syscalls) 的 fcntl-flock
;;; FFI（sizeof-flock 编译期常量），在 boot 环境求值异常抛 out-of-range，
;;; 导致整个 activation 步骤失败——顶层 activation script 的 guard 只
;;; 警告并继续，于是 /etc/passwd|group|shadow 保持空/缺失，所有 getpw
;;; 失败，readiness 链永不完成（表现为 boot 卡死）。
;;;
;;; 本模块提供等价的纯 Scheme 投影：在 activation 时（我们是唯一进程，
;;; 无需锁）用同一批纯 Scheme 函数重建三个文件，不依赖 FFI flock。
;;; 幂等：user+group-databases 读当前文件保留 stateful 位（UID/GID/
;;; shell/password），重复运行结果与上游一致。
;;;
;;; 单写者模型（docs/security.md / system-home-boundaries.md）：
;;;   /etc/{passwd,group,shadow} 的唯一 authoritative writer 是本模块的
;;;   account-databases-activation。interactive 用户的登录 credential
;;;   （/persist/system/accounts/<user>/password.hash，persistent
;;;   verifier）在写库前内联进 shadow 的 password 字段——不存在第二个
;;;   独立 writer 覆盖 shadow。account-state-ready 由只读验证服务
;;;   （account-databases-verify）在验证最终 shadow 后才 provision。

(define-module (guixcfg system accounts)
               #:use-module (gnu services)              ; simple-service
               #:use-module (gnu services shepherd)     ; shepherd-service、shepherd-root-service-type
               #:use-module (gnu system accounts)       ; user-account、user-group、sexp->*
               #:use-module (guix gexp)
               #:use-module (guix modules)              ; source-module-closure
               #:use-module (srfi srfi-1)
               #:export (account-databases-activation
                         account-databases-service
                         account-databases-verify-program
                         account-databases-verify-service))

;; 序列化：与 (gnu system shadow) 的 account-activation 完全一致（那些
;; helper 未导出，这里复刻）。sexp->user-account/sexp->user-group 由
;; (gnu system accounts) 导出，boot 时重建 record。
(define (user-group->gexp group)
  #~(list #$(user-group-name group)
          #$(user-group-password group)
          #$(user-group-id group)
          #$(user-group-system? group)))

(define (user-account->gexp account)
  #~`(#$(user-account-name account)
       #$(user-account-uid account)
       #$(user-account-group account)
       #$(user-account-supplementary-groups account)
       #$(user-account-comment account)
       #$(user-account-home-directory account)
       #$(user-account-create-home-directory? account)
       ,#$(user-account-shell account)             ; 这是 gexp（file-append）
       #$(user-account-password account)
       #$(user-account-system? account)))

;;; credential verifier 路径（persistent canonical backing，root 0600）。
(define (user-credential-path user)
  (string-append "/persist/system/accounts/" user "/password.hash"))

;; 合法 crypt hash 形态：$id$salt$hash（id 数字/字母，salt/hash 不含
;; 冒号与换行）。拒绝空、拒绝 "!"（locked placeholder）。
(define %credential-hash-regex
  "^\\$[0-9a-z]+\\$[^:$]+\\$[^: \n]+$")

(define (account-databases-activation accounts+groups)
  "Return an activation gexp that (re)writes /etc/passwd, /etc/group and
/etc/shadow from ACCOUNTS+GROUPS (the folded account-service-type value:
root + declared users/groups + all service-contributed accounts).  Unlike
upstream 'activate-users+groups', it does NOT use with-file-lock (fcntl
flock FFI) — at activation time we are the only process, so no lock is
needed and the FFI-dependent flock path is bypassed entirely.

本 gexp 是 /etc/{passwd,group,shadow} 的唯一 authoritative writer：
  - user+group-databases 计算三库（保留 stateful 位）；
  - 每个 interactive（非系统、非 root）用户从 persistent verifier
    /persist/system/accounts/<user>/password.hash 读取 crypt hash，
    校验存在/形态后内联进 shadow 的 password 字段；
  - 任何 fail-closed 条件（verifier 缺失/非法）抛错中止：不写任何
    文件，account-state-ready 不会 provision；
  - 写库后验证最终 shadow（目标用户存在、hash 字段 == verifier、
    非 empty/!/locked）才返回 #t。"
  (define accounts
    (delete-duplicates (filter user-account? accounts+groups) eq?))
  (define user-specs
    (map user-account->gexp accounts))
  (define groups
    (delete-duplicates (filter user-group? accounts+groups) eq?))
  (define group-specs
    (map user-group->gexp groups))
  ;; 需要 credential 的 interactive 用户（非系统、非 root——root 无
  ;; verifier；本项目单用户设计：primary user）。
  (define credential-user-names
    (filter-map (lambda (u)
                  (and (not (user-account-system? u))
                       (not (string=? "root" (user-account-name u)))
                       (user-account-name u)))
                accounts))
  ;; name -> verifier-path 的关联列表（evaluator-side 嵌入 gexp）。
  (define credential-assoc
    (map (lambda (name) (cons name (user-credential-path name)))
         credential-user-names))

  (with-imported-modules (source-module-closure
                          '((gnu build accounts)
                            (gnu system accounts)
                            (guix build utils)
                            (srfi srfi-1)       ; delete-duplicates、member、filter
                            (srfi srfi-11)      ; let*-values（与 runtime use-modules 一一对应）
                            (srfi srfi-13)      ; string-trim-both
                            (ice-9 rdelim)      ; read-string（与 runtime use-modules 对应）
                            (ice-9 regex)))     ; string-match
                         #~(begin
                            (use-modules (gnu build accounts)     ; user+group-databases、write-*
                                         (gnu system accounts)    ; sexp->user-account、user-account-*
                                         (guix build utils)       ; mkdir-p
                                         (srfi srfi-1)            ; delete-duplicates、member
                                         (srfi srfi-11)          ; let*-values
                                         (srfi srfi-13)          ; string-trim-both
                                         (ice-9 rdelim)          ; read-string
                                         (ice-9 regex))          ; string-match

                            (define users
                              (map sexp->user-account (list #$@user-specs)))
                            (define user-groups
                              (map sexp->user-group (list #$@group-specs)))

                            ;; 读 persistent credential verifier；任何缺失/非法 fail closed。
                            (define (read-credential-hash path)
                              (unless (file-exists? path)
                                (error "persistent credential missing" path))
                              (let ((hash (string-trim-both
                                           (string-trim-right
                                            (call-with-input-file path
                                                                  (lambda (p)
                                                                    (read-string p)))
                                            #\newline))))
                                (unless (string-match #$%credential-hash-regex hash)
                                  (error "persistent credential malformed" path))
                                hash))

                            ;; 在 shadow entries 中注入 persistent credential。
                            (define (inject-credentials entries)
                              (map (lambda (entry)
                                     (let ((cred (assoc (shadow-entry-name entry)
                                                        '#$credential-assoc)))
                                       (if cred
                                         (shadow-entry
                                          (inherit entry)
                                          (password (read-credential-hash (cdr cred))))
                                         entry)))
                                   entries))

                            ;; 最终验证：从写好的 /etc/shadow 文本解析每个目标 user 的
                            ;; password 字段，与 persistent verifier 比对（非 empty/!/locked）。
                            ;; shadow-entry-password 访问器未从 (gnu build accounts) 导出，
                            ;; 故直接读最终文件验证（也更贴近"验证最终 shadow"语义）。
                            (define (verify-projection)
                              (let ((shadow-text
                                     (call-with-input-file "/etc/shadow"
                                                           (lambda (p) (read-string p)))))
                                (for-each
                                 (lambda (name)
                                   (let* ((line (find (lambda (l)
                                                        (let ((fields (string-split l #\:)))
                                                          (and (pair? fields)
                                                               (string=? (car fields)
                                                                         name))))
                                                      (string-split shadow-text #\newline)))
                                          (fields (and line (string-split line #\:))))
                                     (unless (and fields (pair? (cdr fields)))
                                       (error "account projection missing user" name))
                                     (let ((hash (cadr fields)))
                                       (unless (and hash
                                                    (not (string=? hash ""))
                                                    (not (string=? hash "!"))
                                                    (string=? hash
                                                              (read-credential-hash
                                                               (assoc-ref
                                                                '#$credential-assoc name))))
                                         (error "account projection credential mismatch"
                                                name)))))
                                 '#$credential-user-names)))

                            ;; /var/lib 是系统账号 home 的前置目录（上游在锁外创建）。
                            (mkdir-p "/var/lib")

                            ;; 纯 Scheme 重建三个数据库（原子写：mkstemp! + rename，
                            ;; 无 FFI）。user+group-databases 读当前文件保留 stateful
                            ;; 位（UID/GID/password/shell），重复运行幂等。
                            (let*-values (((group-entries passwd-entries shadow-entries)
                                           (user+group-databases users user-groups)))
                                         (let ((shadow-entries*
                                                (inject-credentials shadow-entries)))
                                           (write-group group-entries)
                                           (write-passwd passwd-entries)
                                           (write-shadow shadow-entries*)
                                           (verify-projection)))

                            ;; system account 的 home（如 /var/empty、/var/run/sshd、
                            ;; /run/dbus）：上游在锁块之后创建，锁失败时也被跳过，
                            ;; 这里补上。
                            (for-each
                             (lambda (user)
                               (when (and (user-account-system? user)
                                          (user-account-create-home-directory? user))
                                 (let* ((home (user-account-home-directory user))
                                        (pwd  (getpwnam (user-account-name user))))
                                   (mkdir-p home)
                                   (chown home (passwd:uid pwd) (passwd:gid pwd))
                                   (chmod home #o700))))
                             (filter (lambda (user)
                                       (and (user-account-system? user)
                                            (user-account-create-home-directory? user)))
                                     users))

                            ;; 共享 home（被多个 system account 使用，如 /var/empty）
                            ;; 转成 root-owned 只读，与上游一致。
                            (for-each (lambda (directory)
                                        (chown directory 0 0)
                                        (chmod directory #o555))
                                      (delete-duplicates
                                       (filter-map (lambda (user)
                                                     (and (user-account-system? user)
                                                          (user-account-home-directory user)))
                                                   users)))

                            #t)))

(define (account-databases-service accounts+groups)
  "Wire ACCOUNTS+GROUPS projection into the activation script.  Runs during
activation (before shepherd), guaranteeing /etc/passwd|group|shadow are
correct regardless of whether the upstream account activation step failed
at its flock.  This is the single authoritative writer for the account
databases."
  (simple-service 'guixcfg-account-databases
                  activation-service-type
                  (account-databases-activation accounts+groups)))

;;; ────────────────────────────────────────────────────────────
;;; 只读验证服务：account-state-ready 的 provision 端。
;;; 不写任何文件——只验证 activation 已写好的最终 shadow。

(define (account-databases-verify-program user)
  "生成只读验证程序：确认 /etc/shadow 中 USER 存在、password 字段 ==
persistent verifier 且非 empty/!/locked。任何失败 exit 非零 →
account-state-ready 不 provision（fail-closed）。"
  (program-file
   "guixcfg-account-databases-verify"
   (with-imported-modules (source-module-closure '((guix build utils)
                                                   (srfi srfi-13)))
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
                             ;; core `any`（generated program 只 import 显式模块）。
                             (define (shadow-line user lines)
                               (let loop ((lines lines))
                                 (and (pair? lines)
                                      (let* ((line (car lines))
                                             (fields (string-split line #\:)))
                                        (if (and (pair? fields)
                                                 (string=? (car fields) user))
                                          line
                                          (loop (cdr lines)))))))
                             (unless (file-exists? hash-path)
                               (error "persistent credential missing" hash-path))
                             (let* ((hash (string-trim-right
                                           (call-with-input-file hash-path
                                                                 (lambda (p) (read-string p)))
                                           #\newline))
                                    (shadow (call-with-input-file "/etc/shadow"
                                                                  (lambda (p) (read-string p))))
                                    (line (shadow-line user
                                                       (string-split shadow #\newline))))
                               (unless (valid-hash? hash)
                                 (error "persistent credential malformed" user))
                               (unless line
                                 (error "target user missing from /etc/shadow" user))
                               (let ((fields (string-split line #\:)))
                                 (unless (and (pair? (cdr fields))
                                              (string=? (cadr fields) hash)
                                              (not (string=? (cadr fields) ""))
                                              (not (string=? (cadr fields) "!")))
                                   (error "shadow credential does not match verifier" user)))
                               #t)))))

(define (account-databases-verify-service user)
  "boot 时验证 account databases projection 已完成且 credential 正确；
成功才 provision account-state-ready。只读——绝不写 /etc/shadow。"
  (simple-service 'guixcfg-account-databases-verify shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(guixcfg-account-databases-verify
                                      account-state-ready))
                         (requirement '(persistent-state-ready
                                        file-systems user-homes))
                         (one-shot? #t)
                         (documentation
                          "Verify the account databases projection (user \
present in /etc/shadow with the persistent credential); provides \
account-state-ready.")
                         (start #~(lambda ()
                                    (zero? (system*
                                            #$(account-databases-verify-program
                                               user)))))
                         (stop #~(const #f))))))
