;;; gnome-keyring application unit：Secret Service / login keyring。
;;; （docs/architecture/desktop-authentication.md）
;;;
;;; 能力边界：
;;;   - system contribution：官方 gnome-keyring-service-type（唯一
;;;     PAM 扩展——pinned 审计：该 service 只扩展 pam-root，daemon
;;;     lifecycle 由 PAM 模块拥有）；
;;;   - home packages：daemon 二进制 + session D-Bus 的
;;;     org.freedesktop.secrets service file（D-Bus activation 只作
;;;     fallback——login 路径的 unlock 由 PAM auto_start 完成）；
;;;   - persistence：keyring vault（XDG_DATA_HOME/keyrings——
;;;     gkd-secret-service.c: g_get_user_data_dir()/keyrings；
;;;     application-owned sensitive mutable state）；
;;;   - 不拥有：polkit（system authority）、declarative .age secrets、
;;;     runtime sockets（/run/user/... 每 session 重建，不持久化）。
;;;
;;; 两阶段 lifecycle（pinned gnome-keyring-48.0 源码审计，gkd-main.c
;;; 注释明示 + LOGIN_TIMEOUT 120 秒超时）：
;;;   Phase 1（PAM，--login）：
;;;     pam_gnome_keyring.so auto_start 以用户身份启动
;;;     gnome-keyring-daemon --daemonize --login——只解锁/创建 login
;;;     keyring 的 stub，不完成初始化；120 秒内无人接管会自动退出。
;;;   Phase 2（session，--start）：
;;;     session startup 必须再跑一次 gnome-keyring-daemon --start，
;;;     通过 control socket 接管 stub、完成初始化、随后退出
;;;     （"This second daemon usually exits"）。
;;;   本模块的 home-services 提供 Phase 2：Home Shepherd one-shot
;;;   服务（session 基础设施，requirement dbus）——不是 niri spawn、
;;;   不是 shell、不是系统 shepherd。
;;;
;;; D-Bus activation（org.freedesktop.secrets.service 的
;;; --start --foreground）同样是 --start 语义：stub 存活窗口内可接管
;;; 它；stub 超时退出后激活的是全新 daemon——login keyring 未解锁。
;;; 因此 D-Bus activation 不是完整 session startup 的等价替代。
;;;
;;; PAM mapping 只配置本系统实际使用的 service（pinned 默认是
;;; gdm-password——本系统用 greetd，必须整体替换）：
;;;   greetd → login（用户会话：auth 保存密码 token；session
;;;            auto_start 解锁 login keyring 并以用户启动 daemon——
;;;            模块自身 fork 后 setuid 到 PAM 用户，greetd worker 的
;;;            session 阶段以 root 运行也不影响）
;;;   login  → login（mingetty tty2-6 console fallback 同样解锁）
;;;   passwd → passwd（passwd 改密码时同步 keyring 密码）

(define-module (guixcfg apps gnome-keyring definition)
               #:use-module (gnu packages gnome)    ; gnome-keyring
               #:use-module (gnu services)          ; service
               #:use-module (gnu services desktop)  ; gnome-keyring-service-type、gnome-keyring-configuration
               #:use-module (gnu services shepherd) ; shepherd-service
               #:use-module (gnu home services shepherd) ; home-shepherd-service-type
               #:use-module (guix gexp)             ; file-append
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%gnome-keyring))

(define %gnome-keyring
  (application
   (name 'gnome-keyring)
   (home-packages (list gnome-keyring))
   (home-services
    ;; Phase 2：session --start initializer（两阶段 lifecycle 的
    ;; 第二半；Phase 1 = PAM auto_start）。one-shot：--start 接管
    ;; PAM stub 后自身退出（上游语义），不做成常驻 daemon。
    (list (simple-service
           'gnome-keyring-session-initializer
           home-shepherd-service-type
           (list (shepherd-service
                  (documentation
                   "Complete GNOME Keyring Secret Service session \
initialization: hook the PAM-created --login daemon via --start.")
                  (provision '(gnome-keyring-initializer))
                  (requirement '(dbus))   ; session D-Bus 就绪后接管
                  (one-shot? #t)
                  (auto-start? #t)
                  (modules '((shepherd support))) ; %user-log-dir
                  (start #~(make-forkexec-constructor
                            (list #$(file-append gnome-keyring
                                                 "/bin/gnome-keyring-daemon")
                                  "--start")
                            #:log-file
                            (string-append %user-log-dir
                                           "/gnome-keyring-start.log")))
                  (stop #~(make-kill-destructor)))))))
   (system-services
    (list (service gnome-keyring-service-type
                   (gnome-keyring-configuration
                    (pam-services '(("greetd" . login)
                                    ("login" . login)
                                    ("passwd" . passwd)))))))
   (persistence
    (list (application-persistence-rule
           (name 'keyrings)
           (backing "gnome-keyring/keyrings") ; backing root 相对（persistence.md）
           (consumer ".local/share/keyrings") ; HOME 相对（XDG_DATA_HOME/keyrings）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
