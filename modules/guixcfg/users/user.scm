;;; Primary user profile：用户结构性事实的唯一 authoritative source。
;;; Host 只负责 select（(users (list %primary-user-account))），不再
;;; 定义 username/uid/groups/shell 等 user facts。
;;;
;;; structural facts 已中立提取到 (guixcfg users facts)（channel-free，
;;; 供 Blue 等轻量环境直接加载）；本模块以别名保持原有导出（同一
;;; 对象/同语义，先例：hosts/vm.scm 对 storage policies 的别名），
;;; 并持有需要 heavy import 的部分（<user-account> 构造与 shell
;;; file-like 值——bash 模块毒化 blue 编译路径，见 facts.scm 头部）。
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
               #:use-module (gnu packages bash)    ; bash（shell file-like 值）
               #:use-module (guix gexp)
               #:use-module (guix records)
               #:use-module (guixcfg users facts)  ; structural facts（re-export 原名）
               #:re-export (user-profile
                            user-profile?
                            user-profile-name
                            user-profile-uid
                            user-profile-group
                            user-profile-supplementary-groups
                            user-profile-shell
                            user-profile-home-directory
                            user-profile-comment
                            user-profile-password-secret
                            %primary-user)
               #:export (primary-user-account))

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
     ;; shell 的 file-like 值权威在本模块（facts 无法 import bash——
     ;; 毒化 blue 编译路径；值未被结构化，见 facts.scm 头部）。
     (shell (or (user-profile-shell u)
                (file-append bash "/bin/bash")))
     (password #f))))
