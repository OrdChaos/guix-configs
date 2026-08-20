;;; gnome-keyring application unit：Secret Service / login keyring。
;;; （docs/architecture/desktop-authentication.md）
;;;
;;; 架构（2026-08 正式切换，告别 PAM login-password handoff）：
;;;   GNOME Keyring master credential = repository-owned encrypted
;;;   application secret（secrets/master.age）；
;;;   runtime 经现有 guixcfg secret publisher 解密到 /run（ordinary
;;;   domain——解密失败绝不阻塞登录）；
;;;   一个 user-session service（Home Shepherd）独占 daemon 的
;;;   启动/解锁/运行/退出生命周期（pinned 审计：Model 1——
;;;   --foreground --unlock --components=secrets，密码经 stdin；
;;;   gkd-main.c read_login_password 全量读取 stdin，解锁在
;;;   initialization 块无条件执行）。
;;;
;;; 核心 separation：login authentication（greetd/PAM 决定能否登录）
;;; ≠ keyring unlocking（本服务决定能否解锁 vault）。两者不共享
;;; password lifecycle；passwd 不再同步 keyring 密码（设计目标）。
;;;
;;; 不变量：
;;;   - exactly one daemon owner（本服务）；无 PAM、无 niri、无 shell
;;;     启动（测试 GK5/GK7 断言）；
;;;   - 密码绝不进 argv/env/日志/repo/store（runtime 仅 /run 明文，
;;;     用户明确接受）；
;;;   - D-Bus activation 只是 fallback（本服务先占有
;;;     org.freedesktop.secrets）；
;;;   - vault（~/.local/share/keyrings ⇄ data-app backing）是
;;;     application-owned mutable state；runtime sockets
;;;     （/run/user/<uid>/keyring）每 session 重建；
;;;   - 同一用户已有 daemon（control socket 存在，如其他会话先启动）
;;;     时本服务 no-op 退出——每用户单 daemon。

(define-module (guixcfg apps gnome-keyring definition)
               #:use-module (gnu packages gnome)    ; gnome-keyring
               #:use-module (gnu home services shepherd) ; home-shepherd-service-type
               #:use-module (gnu services)          ; service、simple-service
               #:use-module (gnu services shepherd) ; shepherd-service
               #:use-module (guix gexp)             ; program-file、file-append、local-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:use-module (guixcfg security secrets) ; secret-decl、runtime-secret-target
               #:use-module (guixcfg users user)    ; %primary-user
               #:export (%gnome-keyring))

;; keyring master credential（stable credential，非 generation 配置）：
;; plaintext 绝不进入 repo/store/argv/env/log——runtime 只以 /run
;; 明文存在（用户明确接受）。normal reconfigure 不轮换；显式维护
;; 操作才允许（须先 rekey 现有 vault）。
(define %gnome-keyring-master-secret
  (secret-decl
   (name 'gnome-keyring-master)
   (scope 'user)                    ; deployment target：user runtime
   (domain 'ordinary)               ; 失败绝不阻塞 greetd login
   (source (local-file "secrets/master.age" "gnome-keyring-master.age"))
   (target-name "gnome-keyring-master")
   (owner-user (user-profile-name %primary-user))
   (mode #o400)))

;; runtime plaintext 目标（canonical convention 推导）：
;; /run/guixcfg-secrets-ordinary/users/<user>/gnome-keyring-master
;; （owner=<user>，mode 0400——ordinary publisher 语义）。
(define %gnome-keyring-master-target
  (runtime-secret-target %gnome-keyring-master-secret
                         (user-profile-name %primary-user)))

;; 会话 wrapper：检查单 daemon 不变量 → 密码经 stdin 文件重定向注入
;; （不出现于 argv/env）→ exec foreground daemon（shepherd 追踪 PID）。
;; secret 文件缺失 → 有界等待后重定向失败 → 服务失败（keyring
;; 不可用，登录不受影响——ordinary domain）。
(define %gnome-keyring-session-wrapper
  (program-file
   "gnome-keyring-session"
   #~(begin
       (use-modules (guix build utils))
       (let ((control (string-append (or (getenv "XDG_RUNTIME_DIR") "")
                                     "/keyring/control"))
             (secret #$%gnome-keyring-master-target))
         ;; 每用户单 daemon：control socket 已存在 = 其他会话已启动
         ;; daemon（本用户由它服务）→ no-op。
         (when (and (not (string-null? control))
                    (file-exists? control))
           (exit 0))
         ;; master 明文文件依赖：boot 时 ordinary publisher 部署；
         ;; reconfigure 升级期间可能滞后（旧 generation 的 deploy 不含
         ;; 新 secret）——有界等待最多 60 秒自愈，避免启动即失败触发
         ;; shepherd 终止处理的边缘路径。正常登录时文件早已存在，
         ;; 第一次检查即通过（零延迟）。
         (let loop ((tries 60))
           (unless (file-exists? secret)
             (if (zero? tries)
                 (exit 1)             ; fail closed：keyring 不可用
                 (begin (sleep 1) (loop (- tries 1))))))
         (execl "/bin/sh" "sh" "-c"
                (string-append
                 "exec " #$(file-append gnome-keyring
                                        "/bin/gnome-keyring-daemon")
                 " --foreground --unlock --components=secrets < "
                 secret))))))

(define %gnome-keyring
  (application
   (name 'gnome-keyring)
   (home-packages (list gnome-keyring))
   (home-services
    (list (simple-service
           'gnome-keyring-session
           home-shepherd-service-type
           (list (shepherd-service
                  (documentation
                   "GNOME Keyring Secret Service session daemon: start \
exactly one daemon and unlock the login keyring with the \
repository-owned master credential (runtime plaintext under /run).")
                  (provision '(gnome-keyring-session))
                  (requirement '(dbus)) ; session D-Bus 就绪后启动
                  (one-shot? #t)        ; daemon 退出 = 会话结束，不 respawn
                  (modules '((shepherd support))) ; %user-log-dir
                  (start #~(make-forkexec-constructor
                            (list #$%gnome-keyring-session-wrapper)
                            #:log-file
                            (string-append %user-log-dir
                                           "/gnome-keyring-session.log")))
                  (stop #~(make-kill-destructor)))))))
   ;; 无 system-services：PAM 不再参与 keyring（/etc/pam.d/greetd
   ;; 无 pam_gnome_keyring——测试 GK2/GK3 断言）。
   (persistence
    (list (application-persistence-rule
           (name 'keyrings)
           (backing "gnome-keyring/keyrings") ; backing root 相对（persistence.md）
           (consumer ".local/share/keyrings") ; HOME 相对（XDG_DATA_HOME/keyrings）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))
   (secrets (list %gnome-keyring-master-secret))))
