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

(define-module (guixcfg system accounts)
               #:use-module (gnu services)              ; simple-service
               #:use-module (gnu system accounts)       ; user-account、user-group、sexp->*
               #:use-module (guix gexp)
               #:use-module (guix modules)              ; source-module-closure
               #:use-module (srfi srfi-1)
               #:export (account-databases-activation
                         account-databases-service))

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

(define (account-databases-activation accounts+groups)
  "Return an activation gexp that (re)writes /etc/passwd, /etc/group and
/etc/shadow from ACCOUNTS+GROUPS (the folded account-service-type value:
root + declared users/groups + all service-contributed accounts).  Unlike
upstream 'activate-users+groups', it does NOT use with-file-lock (fcntl
flock FFI) — at activation time we are the only process, so no lock is
needed and the FFI-dependent flock path is bypassed entirely."
  (define accounts
    (delete-duplicates (filter user-account? accounts+groups) eq?))
  (define user-specs
    (map user-account->gexp accounts))
  (define groups
    (delete-duplicates (filter user-group? accounts+groups) eq?))
  (define group-specs
    (map user-group->gexp groups))
  
  (with-imported-modules (source-module-closure
                          '((gnu build accounts)
                            (gnu system accounts)
                            (guix build utils)))
                         #~(begin
                            (use-modules (gnu build accounts)     ; user+group-databases、write-*
                                         (gnu system accounts)    ; sexp->user-account、user-account-*
                                         (guix build utils)       ; mkdir-p
                                         (srfi srfi-1)            ; delete-duplicates、member
                                         (srfi srfi-11))          ; let*-values
                            
                            (define users
                              (map sexp->user-account (list #$@user-specs)))
                            (define user-groups
                              (map sexp->user-group (list #$@group-specs)))
                            
                            ;; 与上游 activate-users+groups 尾部一致：只 chmod 被多个 system
                            ;; account 共享的 home（如 /var/empty）为 root-owned 只读。
                            (define (shared-home-directories accounts)
                              (let loop ((accounts accounts) (seen '()) (result '()))
                                (if (null? accounts)
                                  (reverse result)
                                  (let* ((home (user-account-home-directory (car accounts)))
                                         (already? (member home seen)))
                                    (loop (cdr accounts)
                                          (cons home seen)
                                          (if already? (cons home result) result))))))
                            
                            ;; /var/lib 是系统账号 home 的前置目录（上游在锁外创建）。
                            (mkdir-p "/var/lib")
                            
                            ;; 纯 Scheme 重建三个数据库（原子写：mkstemp! + rename，无 FFI）。
                            ;; user+group-databases 读当前文件保留 stateful 位（UID/GID/
                            ;; password/shell），重复运行幂等。
                            (let*-values (((group-entries passwd-entries shadow-entries)
                                           (user+group-databases users user-groups)))
                                         (write-group group-entries)
                                         (write-passwd passwd-entries)
                                         (write-shadow shadow-entries))
                            
                            ;; system account 的 home（如 /var/empty、/var/run/sshd、
                            ;; /run/dbus）：上游在锁块之后创建，锁失败时也被跳过，这里补上。
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
                            
                            ;; 共享 home（被多个 system account 使用，如 /var/empty）转成
                            ;; root-owned 只读，与上游一致。
                            (for-each (lambda (directory)
                                        (chown directory 0 0)
                                        (chmod directory #o555))
                                      (shared-home-directories
                                       (filter user-account-system? users)))
                            
                            #t)))

(define (account-databases-service accounts+groups)
  "Wire ACCOUNTS+GROUPS projection into the activation script.  Runs during
activation (before shepherd), guaranteeing /etc/passwd|group|shadow are
correct regardless of whether the upstream account activation step failed
at its flock."
  (simple-service 'guixcfg-account-databases
                  activation-service-type
                  (account-databases-activation accounts+groups)))
