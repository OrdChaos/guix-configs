;;; Selected user persistence（System owns）：/home/<user> 本身保持
;;; ephemeral（无状态 root），只有选定的用户数据位置经 bind mount
;;; 来自 /persist/data-home/<user>/。
;;;
;;; <persistent-user-dir> 对每个持久化条目记录两个相对位置：
;;;   backing   /persist/data-home/<user> 下的持久化数据位置
;;;             （嵌套路径合法，如 ".local/share/Trash"）
;;;   consumer  $HOME 下的挂载位置（嵌套路径合法）
;;; backing 与 consumer 不必同名——backing 是持久化侧的 canonical
;;; 位置，consumer 是用户可见的挂载点。
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
               #:use-module (guixcfg storage model)   ; persist-mount-point（/persist 语义路径 authority）
               #:use-module (guixcfg utils home-path) ; ensure-home-parent-directories!
               #:use-module (guixcfg system mount-metadata) ; %persistent-home-mount-options
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure、guix-module-name?
               #:use-module (guix records)
               #:export (<persistent-user-dir>
                         persistent-user-dir
                         make-persistent-user-dir
                         persistent-user-dir?
                         persistent-user-dir-backing
                         persistent-user-dir-consumer
                         %persistent-user-dirs
                         user-persistence-file-systems
                         user-persistence-activation
                         user-persistence-service))

;; 用户数据持久化条目：backing = /persist/data-home/<user> 相对；
;; consumer = $HOME 相对（均可嵌套，如 ".local/share/Trash"）。
(define-record-type* <persistent-user-dir>
  persistent-user-dir make-persistent-user-dir
  persistent-user-dir?
  (backing persistent-user-dir-backing)    ; string
  (consumer persistent-user-dir-consumer)) ; string

;; 持久化用户数据（XDG user directories 全集，与 (guixcfg home xdg)
;; 的 %xdg-user-dirs-service 对应——一致性由 tests/test-user-persistence.scm
;; 回归）+ 仓库 checkout。
;;
;; 明确不持久化 $HOME/.local/share/Trash（home trash）：GLib 的
;; g_local_file_trash 按 st_dev 把普通 HOME 文件判为 home trash
;; （$XDG_DATA_HOME/Trash）；该目录若被做成独立 bind mount，rename
;; 跨 mount → EXDEV，所有普通文件删除失败（2026-08 实测；GLib
;; 2.86 glocalfile.c）。home trash 随 ephemeral /home 每 boot 重建
;; 是符合无状态系统语义的正确行为（docs/architecture/home.md）。
(define %persistent-user-dirs
  (list (persistent-user-dir (backing "guix-configs") (consumer "guix-configs"))
        (persistent-user-dir (backing "Projects") (consumer "Projects"))
        (persistent-user-dir (backing "Desktop") (consumer "Desktop"))
        (persistent-user-dir (backing "Documents") (consumer "Documents"))
        (persistent-user-dir (backing "Downloads") (consumer "Downloads"))
        (persistent-user-dir (backing "Music") (consumer "Music"))
        (persistent-user-dir (backing "Pictures") (consumer "Pictures"))
        (persistent-user-dir (backing "Public") (consumer "Public"))
        (persistent-user-dir (backing "Templates") (consumer "Templates"))
        (persistent-user-dir (backing "Videos") (consumer "Videos"))))

(define (user-persistence-file-systems user)
  "持久化用户数据的 bind mount 声明（/persist/data-home/USER/<backing>
→ /home/USER/<consumer>）。依赖 @persist-data-home 子卷挂载（/persist
先就位），挂载点在 login 前由 file-systems 阶段创建。
options 带桌面集成 metadata（x-gvfs-hide,x-gvfs-trash——共享常量
(guixcfg system mount-metadata)）：经 fstab 声明 + mount-metadata
服务注入 /run/mount/utab，GVfs 据此隐藏实现性挂载并允许
mount-local trash（docs/architecture/home.md）。"
  (let ((persist-root (string-append (persist-mount-point "@persist-data-home") "/" user)))
    (map (lambda (d)
           (file-system
            (device (string-append persist-root "/"
                                   (persistent-user-dir-backing d)))
            (mount-point (string-append "/home/" user "/"
                                        (persistent-user-dir-consumer d)))
            (type "none")
            (flags '(bind-mount))
            (options %persistent-home-mount-options)
            (create-mount-point? #t)
            (check? #f)))
         %persistent-user-dirs)))

(define (user-persistence-activation user)
  "activation gexp：确保 /persist/data-home/USER 与各 backing 存在且
owner 为 USER（首次系统激活自动完成；不重建已有用户数据）。已有的
存量目录的迁移是显式人工步骤（docs/operations/installation.md——先
迁移到 /persist 再 reconfigure 启用 bind，避免静默覆盖）。

嵌套 consumer（如 .local/share/Trash）的 HOME 侧中间层（.local、
.local/share）由 create-mount-point? 以 root 建出——中间父目录
ownership 归还 USER 走共享原语 (guixcfg utils home-path)
（AGENT.md §12：只 chown 直接 parent 会留下 root-owned 中间层，
USER 后续写入 EACCES）。

注意：/home/USER 本身是 ephemeral，但 file-systems 阶段为 bind mount
创建挂载点时会把 /home/USER 以 root:root 0755 建出；guix 的
activate-user-home 对已存在的 home 整体跳过（不 chown），导致用户
无法在 ~ 顶层写入。这里显式恢复 home 的 owner/权限（与 guix 新建
home 的语义一致：0700 + 用户所有）。"
  ;; 预计算 (backing consumer) 对注入 gexp——纯数据，runtime 无模块
  ;; 依赖（AGENT.md §3）。
  (let ((entries (map (lambda (d)
                        (list (persistent-user-dir-backing d)
                              (persistent-user-dir-consumer d)))
                      %persistent-user-dirs)))
    (with-imported-modules
     (source-module-closure '((guix build utils)
                              (guixcfg utils home-path))
                            #:select? (lambda (name)
                                        (or (guix-module-name? name)
                                            (eq? (car name) 'guixcfg))))
     #~(begin
        (use-modules (guix build utils)
                     (guixcfg utils home-path))
        (let* ((persist (string-append "/persist/data-home/" #$user))
               (home (string-append "/home/" #$user))
               (uid (passwd:uid (getpw #$user)))
               (gid (passwd:gid (getpw #$user))))
          (mkdir-p persist)
          (chown persist uid gid)
          (for-each
           (lambda (entry)
             (let ((backing (car entry))
                   (consumer (cadr entry)))
               ;; persist 侧 backing（嵌套路径 mkdir-p 全建）
               (let ((src (string-append persist "/" backing)))
                 (mkdir-p src)
                 (chown src uid gid))
               ;; HOME 侧中间父目录 owner 归还 USER（共享原语；挂载点
               ;; 本身由 file-systems 创建，bind 后无碍）。
               (ensure-home-parent-directories! home consumer uid gid)))
           '#$entries)
          ;; /home/USER 恢复标准语义（见上）。mkdir-p 只补缺失目录，
          ;; 不覆盖已存在的挂载点。
          (mkdir-p home)
          (chown home uid gid)
          (chmod home #o700))))))

(define (user-persistence-service user)
  "把 selected user 持久化目录创建挂到系统 activation。"
  (simple-service 'user-persistence activation-service-type
                  (user-persistence-activation user)))
