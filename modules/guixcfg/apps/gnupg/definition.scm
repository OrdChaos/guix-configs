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
;;;   - gpg-agent 由 Home Shepherd 全生命周期托管：长驻 service
;;;     （provision gpg-agent，requirement gnupg-session）以
;;;     systemd-style socket activation 启动（make-systemd-constructor
;;;     + --deprecated-supervised，pinned gnupg 2.5.20；upstream
;;;     home-gpg-agent-service-type 同款构造形态，ssh-support? #f——
;;;     本仓库不使用 gpg-agent 的 SSH agent 语义）。socket 落在
;;;     GNUPGHOME（/run/user/<uid>/gnupg，0700），随 session 消亡；
;;;     不再依赖 gpg 按需 self-spawn（--daemon）；
;;;   - 本 key 带 passphrase：签名/解密时经 pinentry 提示（已含
;;;     pinentry-gtk2），agent 按 gpg-agent.conf 的 cache-ttl 缓存——
;;;     ephemeral GNUPGHOME 下缓存随 session 结束失效，每 session
;;;     至多提示一次。passphrase 本身不入仓库（age 密文只保护
;;;     ciphertext 的传输/静止；两者是不同层的防线）。
;;;   - gpg.conf 与 gpg-agent.conf 分开：agent 选项（pinentry-program、
;;;     cache-ttl）放 gpg-agent.conf；放进 gpg.conf 会让 gpg 报
;;;     invalid option 并以 exit 2 中止（2026-08 VM 实测教训）。
;;;     gpg-agent.conf 由本模块生成（%gnupg-agent-conf：mixed-text-
;;;     file 内嵌 pinentry-gtk-2 的 build-time store 路径）——静态
;;;     文件无法携带版本相关的 store 路径；缺失 pinentry-program 时
;;;     带 passphrase 的 key 签名失败 "No pinentry"（2026-09 VM 实测
;;;     根因，见 %gnupg-agent-conf 注释）。
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
               #:use-module (guix gexp)                    ; local-file、plain-file、program-file、file-append、mixed-text-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg security secrets)     ; secret-decl、runtime-secret-target
               #:use-module (guixcfg users user)           ; %primary-user
               #:export (%gnupg
                         %gnupg-agent-conf))

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

;; gpg-agent 运行时配置（生成物，非静态文件）：pinentry-program
;; 指向 pinentry-gtk-2 的 build-time store 路径——静态文件无法携带
;; 版本相关的 store 路径（每次 reconfigure 后本生成物随 wrapper 一起
;; 刷新，路径与当前 home profile 闭包一致）。本 key 带 passphrase：
;; 签名/解密必须经 pinentry 提示；agent 找不到 pinentry 时直接报
;; "No pinentry"，所有签名失败（2026-09 VM 实测根因）。
;;
;; 会话内链路：gpg 客户端把自身 DISPLAY（图形会话 = :0）经 OPTION
;; 传给 agent，agent 再传给 pinentry。pinentry-gtk-2 是
;; FALLBACK_CURSES 构建——无 DISPLAY 时走 curses 路径（依赖 agent
;; dup 的客户端 tty），因此图形会话（GTK 窗口）与带 pty 的 SSH
;; 会话（curses 终端）两条路径都可用（2026-09 VM 实测）。无 tty 且
;; 无 DISPLAY 的上下文（如非交互 ssh 单行命令）无处可提示，签名
;; 失败 "Inappropriate ioctl for device"——预期行为，非配置缺陷。
(define %gnupg-agent-conf
  (mixed-text-file
   "gpg-agent.conf"
   "# Declarative gpg-agent configuration — generated by the guixcfg gnupg\n"
   "# application (definition.scm, %gnupg-agent-conf).  pinentry-program is\n"
   "# resolved from the pinned pinentry-gtk2 package at build time; the session\n"
   "# service copies this file into the ephemeral GNUPGHOME.\n"
   "#\n"
   "# The secret key is passphrase-protected; the agent caches it for the\n"
   "# session.  With an ephemeral GNUPGHOME the cache dies with the\n"
   "# session, so generous TTLs mean at most one pinentry prompt per\n"
   "# session (single-user machine).\n"
   "pinentry-program " (file-append pinentry-gtk2 "/bin/pinentry-gtk-2") "\n"
   "default-cache-ttl 3600\n"
   "max-cache-ttl 86400\n"))

;; session one-shot wrapper：重建 ephemeral GNUPGHOME 并幂等导入
;; key。只用 core/posix bindings（与 ssh/gnome-keyring 同一模式；
;; 失败 = 服务 failed，登录不受影响——ordinary domain 语义）。
;; 本 one-shot 不启动任何 daemon（gpg-agent 由长驻 service 托管）。
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
      ;; 2. gpg.conf 与 gpg-agent.conf 拷贝（store 只读 symlink 不可
      ;;    用：gpg 要求 homedir 文件属主为当前用户、权限 0600；
      ;;    agent 选项在 gpg-agent.conf（%gnupg-agent-conf 生成物，
      ;;    含 pinentry-program）——放进 gpg.conf 会使 gpg exit 2 中止）
      (copy-file #$(local-file "gpg.conf" "gnupg-gpg-conf")
                 (string-append gnupg-home "/gpg.conf"))
      (chmod (string-append gnupg-home "/gpg.conf") #o600)
      (copy-file #$%gnupg-agent-conf
                 (string-append gnupg-home "/gpg-agent.conf"))
      (chmod (string-append gnupg-home "/gpg-agent.conf") #o600)
      ;; 3. 有界等待 runtime secret（boot 时 ordinary publisher
      ;;    部署；reconfigure 升级期间可能滞后——最多 60 秒自愈）
      (let loop ((tries 60))
        (unless (file-exists? secret)
          (if (zero? tries)
            (exit 1)
            (begin (sleep 1) (loop (- tries 1))))))
      ;; 4. 幂等导入公钥与私钥（--import 已存在 = no-op；导入只需把
      ;;    key 材料写入 private-keys-v1.d，不触发 passphrase 提示
      ;;    ——passphrase 只在签名/解密时经 pinentry 提示）
      (unless (zero? (system* gpg-bin "--homedir" gnupg-home
                              "--batch" "--import"
                              #$(local-file "public-key.asc"
                                            "gnupg-public-key")))
        (exit 1))
      (unless (zero? (system* gpg-bin "--homedir" gnupg-home
                              "--batch" "--import" secret))
        (exit 1)))))

;; gpg-agent 长驻 service（Home Shepherd 全生命周期托管）。
;; 构造形态取自 pinned upstream home-gpg-agent-service-type
;; （模块 (gnu home services gnupg)：make-systemd-constructor +
;; --deprecated-supervised + endpoint + make-systemd-destructor），
;; 但 ssh-support? 语义保持 #f——不提供 ssh socket、不注入
;; SSH_AUTH_SOCK（本仓库 ssh app 是纯 client 配置，无 agent）。
;;
;; supervised 模式只传 std socket 合法：pinned gnupg 2.5.20
;; agent/gpg-agent.c map_supervised_sockets 按 LISTEN_FDNAMES
;; 分配 fd，"std" 是标准 socket 标签；缺失的 ssh/browser/extra
;; 直接不启用；仅要求 fd 数与 fdnames 数一致。std 即可服务
;; gpg/pinentry/keyserver 全部现有使用路径。
;;
;; 细节：
;;   - requirement gnupg-session：GNUPGHOME（0700）先于 endpoint
;;     bind 存在（open-sockets 也会 mkdir-p，但顺序显式化）；
;;   - #:lazy-start? #f：登录即启动并占住 socket，避免与 gpg 的
;;     按需 self-spawn 竞争（GnuPG 2.5.20 README 的 supervised
;;     竞态警告）；
;;   - 显式传 (environ) + GNUPGHOME：shepherd 默认环境不含会话
;;     env；pinentry 需要 DISPLAY/DBUS_SESSION_BUS_ADDRESS，
;;     agent 需要从 ephemeral homedir 读 gpg-agent.conf
;;     （cache-ttl 等 agent 选项）；
;;   - respawn? #f：session 生命周期语义（与 gnome-keyring/niri
;;     一致）；第一版不做自动 respawn。
(define %gnupg-gpg-agent-service
  (shepherd-service
   (documentation
    "GnuPG agent under Home Shepherd supervision: socket-activated \
gpg-agent (--deprecated-supervised) owning the ephemeral GNUPGHOME \
runtime sockets under /run/user/<uid>/gnupg.")
   (provision '(gpg-agent))
   (requirement '(gnupg-session))
   (respawn? #f)
   (modules '((shepherd support))) ; %user-runtime-dir、endpoint 辅助
   (start #~(make-systemd-constructor
             (list #$(file-append gnupg "/bin/gpg-agent")
                   ;; pinned gnupg 2.5.20：--supervised 已改名
                   ;; --deprecated-supervised（upstream home-gpg-agent
                   ;; service 同款参数）
                   "--deprecated-supervised")
             (list (endpoint
                    (make-socket-address
                     AF_UNIX
                     (string-append %user-runtime-dir
                                    "/gnupg/S.gpg-agent"))
                    #:name "std"
                    #:socket-directory-permissions #o700))
             #:environment-variables
             (cons #$(string-append "GNUPGHOME=" %gnupg-home-dir)
                   (environ))
             #:lazy-start? #f))
   (stop #~(make-systemd-destructor))))

(define %gnupg
  (application
   (name 'gnupg)
   (home-packages (list gnupg pinentry-gtk2)) ; pinentry-gtk2：本 key
   ; 带 passphrase，签名/解密经它提示（%gnupg-agent-conf 的
   ; pinentry-program 指向本包 build-time 路径）
   (home-services
    (list (simple-service
           'gnupg-env
           home-environment-variables-service-type
           (list (cons "GNUPGHOME" %gnupg-home-dir)))
          (simple-service
           'gnupg-signing-config
           home-files-service-type
           `((".config/git/signing" ,%gnupg-git-signing-file)))
          (simple-service
           'gnupg-session
           home-shepherd-service-type
           (list (shepherd-service
                  (documentation
                   "GnuPG session wiring: rebuild the ephemeral \
GNUPGHOME and import the repository-owned secret key (runtime \
plaintext under /run; plaintext secret key never lands on disk).")
                  (provision '(gnupg-session))
                  (one-shot? #t)        ; 初始化完成后即退出
                  (respawn? #f)         ; 一次性语义，不 respawn
                  (modules '((shepherd support))) ; %user-log-dir
                  (start #~(make-forkexec-constructor
                            (list #$%gnupg-session-wrapper)
                            #:log-file
                            (string-append %user-log-dir
                                           "/gnupg-session.log")))
                  (stop #~(make-kill-destructor)))))
          (simple-service
           'gnupg-gpg-agent
           home-shepherd-service-type
           (list %gnupg-gpg-agent-service))))
   ;; 无 persistence rule：GNUPGHOME 是 runtime-only（见文件头）。
   (secrets (list %gnupg-secret-key-secret))))
