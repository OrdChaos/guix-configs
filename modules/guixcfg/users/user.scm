;;; Primary user profile：用户结构性事实的唯一 authoritative source。
;;; Host 只负责 select（(users (list %primary-user-account))），不再
;;; 定义 username/uid/groups/shell 等 user facts。
;;;
;;; 边界：
;;;   - 这里是 structural configuration（Guix evaluation 必需的声明式
;;;     事实）——不含任何 secret 值；
;;;   - password 只保存 logical secret 引用（install secret 名），
;;;     hash 由 installer 在 LUKS 建立后注入目标系统 shadow（见
;;;     tools/secrets.scm 与 docs/architecture/secrets.md）；
;;;   - Guix Home 绑定、persistence 路径、SSH 允许用户等消费方都从
;;;     本模块取 name，不再各自硬编码。

(define-module (guixcfg users user)
               #:use-module (gnu system accounts)  ; user-account
               #:use-module (gnu packages bash)    ; bash
               #:use-module (guix gexp)
               #:use-module (guix records)
               #:export (user-profile
                         user-profile?
                         user-profile-name
                         user-profile-uid
                         user-profile-group
                         user-profile-supplementary-groups
                         user-profile-shell
                         user-profile-home-directory
                         user-profile-comment
                         user-profile-password-secret
                         %primary-user
                         primary-user-account))

(define-record-type* <user-profile> user-profile make-user-profile
                     user-profile?
                     (name                user-profile-name)                 ; string
                     (uid                 user-profile-uid)                  ; integer
                     (group               user-profile-group)                ; string
                     (supplementary-groups user-profile-supplementary-groups) ; list of strings
                     (shell               user-profile-shell)                ; file-like
                     (home-directory      user-profile-home-directory)       ; string
                     (comment             user-profile-comment)              ; string
                     (password-secret     user-profile-password-secret))     ; symbol（logical name）

;; 当前仓库是 root + one primary user 的单用户设计。
(define %primary-user
  (user-profile
   (name "user")
   (uid 1000)
   (group "users")
   (supplementary-groups '("wheel" "netdev"))
   (shell (file-append bash "/bin/bash"))
   (home-directory "/home/user")
   (comment "VM test user")
   ;; 密码 hash 是 install secret（secrets/install/user-password.hash.age），
   ;; 由 installer 在 LUKS 建立后注入目标系统 shadow；这里只保留逻辑名。
   (password-secret 'primary-user-password)))

(define (primary-user-account)
  "由 %primary-user 生成 <user-account>。password 恒为 #f——hash 不进入
evaluation/store（ephemeral root 下 account activation 复用既有
shadow 条目，安装期注入的 hash 跨 boot/reconfigure 保留，见
docs/architecture/secrets.md 与 tests/test-users.scm）。"
  (let ((u %primary-user))
    (user-account
     (name (user-profile-name u))
     (uid (user-profile-uid u))
     (group (user-profile-group u))
     (supplementary-groups (user-profile-supplementary-groups u))
     (comment (user-profile-comment u))
     (home-directory (user-profile-home-directory u))
     (shell (user-profile-shell u))
     (password #f))))
