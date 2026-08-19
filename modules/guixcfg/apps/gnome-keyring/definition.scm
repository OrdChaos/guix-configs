;;; gnome-keyring application unit：Secret Service / login keyring。
;;; （docs/architecture/desktop-authentication.md）
;;;
;;; 能力边界：
;;;   - system contribution：官方 gnome-keyring-service-type（唯一
;;;     PAM 扩展——pinned 审计：该 service 只扩展 pam-root，daemon
;;;     lifecycle 由 PAM 模块拥有）；
;;;   - home packages：daemon 二进制 + session D-Bus 的
;;;     org.freedesktop.secrets service file（D-Bus activation 只作
;;;      fallback——login 路径的 unlock 由 PAM auto_start 完成）；
;;;   - persistence：keyring vault（XDG_DATA_HOME/keyrings——
;;;     gkd-secret-service.c: g_get_user_data_dir()/keyrings；
;;;     application-owned sensitive mutable state）；
;;;   - 不拥有：polkit（system authority）、declarative .age secrets、
;;;     runtime sockets（/run/user/... 每 session 重建，不持久化）。
;;;
;;; daemon 唯一启动 owner = PAM（pam_gnome_keyring.so auto_start，
;;; 官方 service 生成）——niri/Home/shell 都不再手动启动（B5 不变量，
;;; 测试 test-gnome-keyring.scm GK6）。
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
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%gnome-keyring))

(define %gnome-keyring
  (application
   (name 'gnome-keyring)
   (home-packages (list gnome-keyring))
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
