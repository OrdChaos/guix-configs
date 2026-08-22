;;; ssh application unit：用户级（client）SSH 环境。
;;;
;;; 所有权边界：本应用只负责用户侧 SSH——~/.ssh/config、
;;; authorized_keys、用户私钥 wiring、known_hosts 持久化。系统层
;;; sshd / SSH policy / host keys（system 层持久化，非本应用）归
;;; (guixcfg system ssh)，本应用不碰（docs/architecture/
;;; upstream-boundaries.md）。
;;;
;;; 无状态 root 适配（ephemeral HOME，每 boot 重建）：
;;;   ~/.ssh/config、~/.ssh/authorized_keys、~/.ssh/id_ed25519.pub、
;;;   ~/.ssh/aur.pub
;;;     ← 声明式（本应用目录 colocate，home-files 投影；均为公开
;;;        材料，不进 persistence）；
;;;   ~/.ssh/id_ed25519、~/.ssh/aur（私钥）
;;;     ← symlink → /run 的 ordinary-domain runtime secret（boot 时
;;;        由 generic secrets publisher 解密；plaintext 只存在于
;;;        /run，绝不落盘/进 persistence/git/store）；
;;;   ~/.ssh/known_hosts（唯一 mutable state）
;;;     ← direct reference：ssh config 直接指向 canonical backing
;;;        （application persistence root 下，persistence.md 的
;;;        direct reference 模式，与 system/ssh.scm 的 HostKey 同
;;;        语义）。不用 single-file bind/symlink——OpenSSH 用
;;;        mkstemp+rename 原子更新 known_hosts，rename 会替换
;;;        symlink 本身、bind 挂载点 EBUSY。backing 目录由本应用的
;;;        system activation 创建并归还用户所有（root-owned root
;;;        下用户身份无法 mkdir）。
;;;
;;; 权限模型：~/.ssh 0700（session 服务保证）；私钥 0600（secret-decl
;;; mode，publisher 物化）。
;;;
;;; 不做：sshd 服务端（system 层）、host keys（system 层持久化）、
;;; ~/.ssh 整目录 bind（mutable 与 declarative 混容器）。

(define-module (guixcfg apps ssh definition)
               #:use-module (gnu home services)            ; home-files-service-type
               #:use-module (gnu home services shepherd)   ; home-shepherd-service-type
               #:use-module (gnu services)                 ; simple-service
               #:use-module (gnu services shepherd)        ; shepherd-service
               #:use-module (gnu packages ssh)             ; openssh（客户端）
               #:use-module (guix gexp)                    ; local-file、program-file
               #:use-module (guix modules)                 ; source-module-closure
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg security secrets)     ; secret-decl、runtime-secret-target
               #:use-module (guixcfg system application-persistence) ; %application-persistence-root
               #:use-module (guixcfg users user)           ; %primary-user
               #:export (%ssh))

;; known_hosts canonical backing（direct reference）：从 application
;; persistence root（唯一 authority）拼接相对路径，不写死 root
;; 字面量（test-source-hygiene 禁止 app definition 出现该字面）。
(define %ssh-known-hosts-dir
  (string-append %application-persistence-root "/ssh"))

;; backing 目录创建（system activation，root）：persistence root 是
;; root-owned 子卷，用户身份无法在其中 mkdir——必须在 activation 以
;; root 创建并归还 owner（与 application-persistence-activation /
;; ssh-host-key-activation 同一语义；session 服务只消费，不创建）。
(define (ssh-known-hosts-dir-activation)
  "activation gexp：确保 %SSH-KNOWN-HOSTS-DIR 存在且归 primary user
所有（幂等：mkdir-p 对已存在目录 no-op，chown 重复设置无害）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (let* ((pw (getpw #$(user-profile-name
                                                 %primary-user)))
                                   (dir #$%ssh-known-hosts-dir))
                              (mkdir-p dir)
                              (chown dir (passwd:uid pw)
                                     (passwd:gid pw))))))

;; 用户 SSH 私钥（user scope、ordinary domain——解密/部署失败绝不
;; 阻塞 greetd login；plaintext 仅 /run）。ciphertext colocate 本
;; 应用 secrets/（单一 app owner，AGENT.md §Application layer）。
(define %ssh-user-key-secret
  (secret-decl
   (name 'ssh-user-key)
   (scope 'user)
   (domain 'ordinary)
   (source (local-file "secrets/id_ed25519.age" "ssh-id-ed25519.age"))
   (target-name "id_ed25519")
   (owner-user (user-profile-name %primary-user))
   (mode #o600)))

;; runtime plaintext 目标（canonical convention 推导）：
;; /run/guixcfg-secrets-ordinary/users/<user>/{id_ed25519,aur}
(define %ssh-user-key-target
  (runtime-secret-target %ssh-user-key-secret
                         (user-profile-name %primary-user)))

;; AUR 密钥（同用户第二把 SSH key；只用于访问 aur.archlinux.org，
;; 不进 authorized_keys）。与 id_ed25519 同一生命周期。
(define %ssh-aur-key-secret
  (secret-decl
   (name 'ssh-aur-key)
   (scope 'user)
   (domain 'ordinary)
   (source (local-file "secrets/aur.age" "ssh-aur.age"))
   (target-name "aur")
   (owner-user (user-profile-name %primary-user))
   (mode #o600)))

(define %ssh-aur-key-target
  (runtime-secret-target %ssh-aur-key-secret
                         (user-profile-name %primary-user)))

;; 用户私钥集合：(runtime secret target, ~/.ssh 链接名)。
(define %ssh-user-keys
  (list (cons %ssh-user-key-target "id_ed25519")
        (cons %ssh-aur-key-target "aur")))

;; session one-shot wrapper：有界等待全部 runtime secret → 建 ~/.ssh
;; （0700）与 known_hosts backing 目录 → 各私钥 symlink（幂等：目标
;; 一致跳过，陈旧/非 symlink 替换——ephemeral HOME 下 ~/.ssh 每
;; boot 重建，路径由本应用拥有）→ 防御性 chmod 0600。只用 core
;; bindings（与 gnome-keyring 同一模式；失败 = 服务 failed，登录
;; 不受影响——ordinary domain 语义）。
(define %ssh-session-wrapper
  (program-file
   "ssh-session"
   #~(begin
      (define home (or (getenv "HOME") #$(user-profile-home-directory
                                          %primary-user)))
      (define ssh-dir (string-append home "/.ssh"))
      ;; 1. ~/.ssh 目录（幂等；session 以用户身份运行）。known_hosts
      ;;    backing 由 system activation 创建（root-owned root 下
      ;;    用户无法 mkdir），这里只防御性 chmod。
      (unless (file-exists? ssh-dir) (mkdir ssh-dir))
      (chmod ssh-dir #o700)
      (chmod #$%ssh-known-hosts-dir #o700)
      ;; 2. 有界等待全部 runtime secret（ordinary domain fail-closed：
      ;;    解密发布要么全有要么全无；reconfigure 升级期间可能滞后——
      ;;    最多 60 秒自愈；失败 = 服务 failed，登录不受影响）
      (for-each
       (lambda (target)
         (let loop ((tries 60))
           (unless (file-exists? target)
             (if (zero? tries)
               (exit 1)
               (begin (sleep 1) (loop (- tries 1)))))))
       (map car #$%ssh-user-keys))
      ;; 3. 私钥 symlink（幂等；替换陈旧/非 symlink 目标）+ 防御性
      ;;    权限（publisher 已按 decl 物化 0600；双保险）
      (for-each
       (lambda (entry)
         (let* ((secret (car entry))
                (name (cdr entry))
                (link (string-append ssh-dir "/" name)))
           (catch #t
             (lambda ()
               (unless (string=? (readlink link) secret)
                 (delete-file link)
                 (symlink secret link)))
             (lambda (k . a)
               (catch #t
                 (lambda () (delete-file link))
                 (lambda (k . a) #t))
               (symlink secret link)))
           (chmod secret #o600)))
       #$%ssh-user-keys))))

(define %ssh
  (application
   (name 'ssh)
   (home-packages (list openssh))        ; 客户端工具；sshd 由 system 层提供
   (system-services
    (list (simple-service 'ssh-known-hosts-dir
                          activation-service-type
                          (ssh-known-hosts-dir-activation))))
   (home-services
    (list (simple-service
           'ssh-files
           home-files-service-type
           `((".ssh/config"            ; 声明式（公开，非 secret）
              ,(local-file "config" "ssh-client-config"))
             (".ssh/authorized_keys"
              ,(local-file "authorized_keys" "ssh-authorized-keys"))
             (".ssh/id_ed25519.pub"    ; 公开材料（public key 非 secret）
              ,(local-file "id_ed25519.pub" "ssh-id-ed25519-pub"))
             (".ssh/aur.pub"           ; AUR 公钥（public key 非 secret）
              ,(local-file "aur.pub" "ssh-aur-pub"))))
          (simple-service
           'ssh-session
           home-shepherd-service-type
           (list (shepherd-service
                  (documentation
                   "SSH user session wiring: wait for the ordinary-domain \
runtime private key, then materialize ~/.ssh/id_ed25519 as a symlink \
into /run (plaintext private key never lands on disk or persistence).")
                  (provision '(ssh-session))
                  (one-shot? #t)        ; 进程退出后不 respawn
                  (modules '((shepherd support))) ; %user-log-dir
                  (start #~(make-forkexec-constructor
                            (list #$%ssh-session-wrapper)
                            #:log-file
                            (string-append %user-log-dir
                                           "/ssh-session.log")))
                  (stop #~(make-kill-destructor)))))))
   ;; 无 persistence rule：known_hosts 经 ssh config direct reference
   ;; 持久化（single-file bind/symlink 与 OpenSSH 原子替换冲突——
   ;; 见文件头注释与 docs/architecture/persistence.md）。
   (secrets (list %ssh-user-key-secret %ssh-aur-key-secret))))
