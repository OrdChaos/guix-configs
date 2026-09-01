;;; Primary user profile 的纯 structural facts（channel-free 中立
;;; 提取）。
;;;
;;; 提取动机：Blueprint（blue 的 shell 环境）无法加载
;;; (guixcfg users user)——该模块经 (gnu packages bash)/(gnu system
;;; accounts) 拖入 bootstrap/download 链到 gcrypt/hash，blue 的编译
;;; 路径会对缺少 .go 的 gcrypt 模块 out-of-range 崩溃（两者均实测
;;; 毒化）。本模块只依赖 (guix records)（已证在 blue 环境可编译），
;;; 是 user structural facts 的单一权威源；(guixcfg users user) 以
;;; 别名保持原有导出（同一对象，无第二事实源；先例：hosts/vm.scm
;;; 对 storage policies 的别名）。
;;;
;;; shell 字段：本模块无法构造 bash file-like（bash 模块毒化 blue
;;; 编译），默认 #f；shell 的 file-like 值由 (guixcfg users user)
;;; 的 primary-user-account 解析（该模块本就 import bash）——
;;; user-profile-shell 的**值**权威在 user.scm，访问器与其余事实
;;; 权威在本模块。
;;;
;;; 禁止：复制 username 常量、硬编码用户名。

(define-module (guixcfg users facts)
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
                         %primary-user))

(define-record-type* <user-profile> user-profile make-user-profile
                     user-profile?
                     (name                user-profile-name)                 ; string
                     (uid                 user-profile-uid)                  ; integer
                     (group               user-profile-group)                ; string
                     (supplementary-groups user-profile-supplementary-groups) ; list of strings
                     (shell               user-profile-shell                 ; file-like
                                          (default #f))
                     (home-directory      user-profile-home-directory)       ; string
                     (comment             user-profile-comment)              ; string
                     (password-secret     user-profile-password-secret))     ; symbol（logical name）

;; 当前仓库是 root + one primary user 的单用户设计。
(define %primary-user
  (user-profile
   (name "ordchaos")
   (uid 1000)
   (group "users")
   (supplementary-groups '("wheel" "netdev"))
   (home-directory "/home/ordchaos")
   (comment "序炁")
   ;; 密码 hash 是 install secret（colocate users/secrets/，
   ;; 见本目录 user-password.hash.age），
   ;; 由 installer 在 LUKS 建立后注入目标系统 shadow；这里只保留逻辑名。
   (password-secret 'primary-user-password)))
