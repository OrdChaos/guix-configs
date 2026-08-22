;;; gnupg application unit：用户级 GnuPG/PGP 身份（ephemeral
;;; GNUPGHOME 模型）。
;;;
;;; 用途：git commit/tag 签名（含 Guix channel commit 签名——本 key
;;; 指纹即 virelith channel introduction）、文件加密、邮件签名等。
;;; 排除：smartcard/YubiKey、revocation（明确不做，见评估）。
;;;
;;; 模型（与 ssh app 同一 runtime secret 模式）：
;;;   - secret key 以 age ciphertext colocate（apps/gnupg/secrets/），
;;;     boot 时由 generic publisher 解密到 /run（ordinary domain）；
;;;   - GNUPGHOME 是 ephemeral runtime 目录（/run/user/<uid>/gnupg，
;;;     session 结束时随 XDG_RUNTIME_DIR 消失）——secret key 绝不
;;;     落盘/进 persistence；每 session 由 one-shot 服务重建：
;;;     mkdir 0700 → 拷贝 gpg.conf（600）→ 有界等待 secret → 幂等
;;;     import 公钥与私钥（gpg --import 已存在 = no-op）；
;;;   - gpg-agent 生命周期自动跟随 GNUPGHOME（首次使用自 spawn，
;;;     socket 随 session 消亡），无需 system service；
;;;   - 本 key 带 passphrase：签名/解密时经 pinentry 提示（已含
;;;     pinentry-gtk2），agent 按 gpg.conf 的 cache-ttl 缓存——
;;;     ephemeral GNUPGHOME 下缓存随 session 结束失效，每 session
;;;     至多提示一次。passphrase 本身不入仓库（age 密文只保护
;;;     ciphertext 的传输/静止；两者是不同层的防线）。
;;;
;;; 不做持久化：pubring.kbx/trustdb/tofu 随 session 重建（runtime-only
;;; 起步；验证他人签名由 gpg.conf 的 auto-key-retrieve 兜底。持久化
;;; 会违反 "secret 不进入 persistence"，且 persistence API 只支持
;;; HOME 相对 consumer，覆盖不到 /run/user 路径）。
;;;
;;; git 集成（跨 app 契约）：git app 的 .gitconfig include
;;; ~/.config/git/signing（本 app 经 xdg-config extension 贡献，
;;; 含 user.signingkey + commit.gpgsign）——git app 依赖本 app 启用
;;; （registry 打包启停；缺失文件 git 报错，fail loud）。

(define-module (guixcfg apps gnupg definition)
               #:use-module (gnu home services)            ; home-files 系
               #:use-module (gnu home services shepherd)   ; home-shepherd-service-type
               #:use-module (gnu packages gnupg)           ; gnupg、pinentry-gtk2
               #:use-module (gnu services)                 ; simple-service
               #:use-module (gnu services shepherd)        ; shepherd-service
               #:use-module (guix gexp)                    ; local-file、plain-file、program-file、file-append
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg security secrets)     ; secret-decl、runtime-secret-target
               #:use-module (guixcfg users user)           ; %primary-user
               #:export (%gnupg))

;; ephemeral GNUPGHOME（XDG_RUNTIME_DIR 下；elogind 在最后一个
;; session 结束时删除该目录——与 "关机后一切消失" 的语义一致且更
;; 严格）。静态值注入会话环境变量（home-environment-variables 共享
;; sink）。
(define %gnupg-home-dir
  (string-append "/run/user/"
                 (number->string (user-profile-uid %primary-user))
                 "/gnupg"))

;; secret key（user scope、ordinary domain——失败绝不阻塞登录；
;; plaintext 仅 /run）。ciphertext colocate 本应用 secrets/。
(define %gnupg-secret-key-secret
  (secret-decl
   (name 'gnupg-secret-key)
   (scope 'user)
   (domain 'ordinary)
   (source (local-file "secrets/pgp-secret-key.asc.age"
                       "gnupg-secret-key.age"))
   (target-name "pgp-secret-key.asc")
   (owner-user (user-profile-name %primary-user))
   (mode #o400)))

;; runtime plaintext 目标：
;; /run/guixcfg-secrets-ordinary/users/<user>/pgp-secret-key.asc
(define %gnupg-secret-key-target
  (runtime-secret-target %gnupg-secret-key-secret
                         (user-profile-name %primary-user)))

;; git 签名配置（跨 app 契约）：git app 的 .gitconfig include 本
;; 文件（user.signingkey + commit.gpgsign；keyid 是公开信息）。
(define %gnupg-git-signing-file
  (plain-file
   "git-signing"
   (string-append "[user]\n\tsigningkey = "
                  "FF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE\n"
                  "[commit]\n\tgpgsign = true\n")))

;; session one-shot wrapper：重建 ephemeral GNUPGHOME 并幂等导入
;; key。只用 core/posix bindings（与 ssh/gnome-keyring 同一模式；
;; 失败 = 服务 failed，登录不受影响——ordinary domain 语义）。
(define %gnupg-session-wrapper
  (program-file
   "gnupg-session"
   #~(begin
      (define gnupg-home #$%gnupg-home-dir)
      (define secret #$%gnupg-secret-key-target)
      (define gpg-bin #$(file-append gnupg "/bin/gpg"))
      ;; 1. ephemeral GNUPGHOME（0700；session 以用户身份运行，
      ;;    目录归用户所有）
      (unless (file-exists? gnupg-home) (mkdir gnupg-home))
      (chmod gnupg-home #o700)
      ;; 2. gpg.conf 拷贝（store 只读 symlink 不可用：gpg 要求
      ;;    homedir 文件属主为当前用户、权限 0600）
      (copy-file #$(local-file "gpg.conf" "gnupg-gpg-conf")
                 (string-append gnupg-home "/gpg.conf"))
      (chmod (string-append gnupg-home "/gpg.conf") #o600)
      ;; 3. 有界等待 runtime secret（boot 时 ordinary publisher
      ;;    部署；reconfigure 升级期间可能滞后——最多 60 秒自愈）
      (let loop ((tries 60))
        (unless (file-exists? secret)
          (if (zero? tries)
            (exit 1)
            (begin (sleep 1) (loop (- tries 1))))))
      ;; 4. 幂等导入公钥与私钥（--import 已存在 = no-op；本 key 无
      ;;    passphrase，导入不需要交互）
      (unless (zero? (system* gpg-bin "--homedir" gnupg-home
                              "--batch" "--import"
                              #$(local-file "public-key.asc"
                                            "gnupg-public-key")))
        (exit 1))
      (unless (zero? (system* gpg-bin "--homedir" gnupg-home
                              "--batch" "--import" secret))
        (exit 1)))))

(define %gnupg
  (application
   (name 'gnupg)
   (home-packages (list gnupg pinentry-gtk2)) ; pinentry：安全网（key
   ; 无 passphrase，正常不需要；未来加 passphrase/smartcard 时兜底）
   (home-services
    (list (simple-service
           'gnupg-env
           home-environment-variables-service-type
           (list (cons "GNUPGHOME" %gnupg-home-dir)))
          (simple-service
           'gnupg-signing-config
           home-xdg-configuration-files-service-type
           `(("git/signing" ,%gnupg-git-signing-file)))
          (simple-service
           'gnupg-session
           home-shepherd-service-type
           (list (shepherd-service
                  (documentation
                   "GnuPG session wiring: rebuild the ephemeral \
GNUPGHOME and import the repository-owned secret key (runtime \
plaintext under /run; plaintext secret key never lands on disk).")
                  (provision '(gnupg-session))
                  (one-shot? #t)        ; 进程退出后不 respawn
                  (modules '((shepherd support))) ; %user-log-dir
                  (start #~(make-forkexec-constructor
                            (list #$%gnupg-session-wrapper)
                            #:log-file
                            (string-append %user-log-dir
                                           "/gnupg-session.log")))
                  (stop #~(make-kill-destructor)))))))
   ;; 无 persistence rule：GNUPGHOME 是 runtime-only（见文件头）。
   (secrets (list %gnupg-secret-key-secret))))
