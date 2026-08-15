;;; Selected user persistence（System owns）：/home/<user> 本身保持
;;; ephemeral（无状态 root），只有选定的用户数据目录经 bind mount
;;; 来自 /persist/data-home/<user>/。
;;;
;;; 所有权边界：映射、目录创建、ownership 由 Guix System 建立；
;;; Guix Home 不挂载 /persist；用户数据内容（/persist 侧）由
;;; Persistent data layer 拥有，System activation 绝不重建/覆盖。
;;;
;;; 无状态 root 适配：root generation 每次重建 /home（空），bind
;;; 挂载在用户登录前由 file-systems 阶段就位——用户写入永远落在
;;; /persist，generation 更新后数据保留，未声明的 ephemeral 垃圾消失。

(define-module (guixcfg system user-persistence)
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu system file-systems) ; file-system
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure
               #:export (%persistent-user-dirs
                         user-persistence-file-systems
                         user-persistence-activation
                         user-persistence-service))

;; 持久化目录（后续按应用状态需求单独扩展）。
(define %persistent-user-dirs
  '("guix-configs"
    "Projects"
    "Documents"
    "Downloads"
    "Pictures"))

(define (user-persistence-file-systems user)
  "SELECTED 用户目录的 bind mount 声明（/persist/data-home/USER/<d>
→ /home/USER/<d>）。依赖 @persist-data-home 子卷挂载（/persist
先就位），挂载点在 login 前由 file-systems 阶段创建。"
  (let ((persist-root (string-append "/persist/data-home/" user)))
    (map (lambda (d)
           (file-system
            (device (string-append persist-root "/" d))
            (mount-point (string-append "/home/" user "/" d))
            (type "none")
            (flags '(bind-mount))
            (create-mount-point? #t)
            (check? #f)))
         %persistent-user-dirs)))

(define (user-persistence-activation user)
  "activation gexp：确保 /persist/data-home/USER 与 selected 子目录
存在且 owner 为 USER（首次系统激活自动完成；不重建已有用户数据）。
已有的 /home/USER/guix-configs 等存量目录的迁移是显式人工步骤
（docs/installation.md 第 30 节——先迁移到 /persist 再 reconfigure
启用 bind，避免静默覆盖）。

注意：/home/USER 本身是 ephemeral，但 file-systems 阶段为 bind mount
创建挂载点时会把 /home/USER 以 root:root 0755 建出；guix 的
activate-user-home 对已存在的 home 整体跳过（不 chown），导致用户
无法在 ~ 顶层写入。这里显式恢复 home 的 owner/权限（与 guix 新建
home 的语义一致：0700 + 用户所有）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (let* ((persist (string-append "/persist/data-home/" #$user))
                                   (home (string-append "/home/" #$user))
                                   (uid (passwd:uid (getpw #$user)))
                                   (gid (passwd:gid (getpw #$user))))
                              (mkdir-p persist)
                              (chown persist uid gid)
                              (for-each
                               (lambda (d)
                                 (let ((src (string-append persist "/" d)))
                                   (mkdir-p src)
                                   (chown src uid gid)))
                               '#$%persistent-user-dirs)
                              ;; /home/USER 恢复标准语义（见上）。mkdir-p 只补缺失目录，
                              ;; 不覆盖已存在的挂载点。
                              (mkdir-p home)
                              (chown home uid gid)
                              (chmod home #o700)))))

(define (user-persistence-service user)
  "把 selected user 持久化目录创建挂到系统 activation。"
  (simple-service 'user-persistence activation-service-type
                  (user-persistence-activation user)))
