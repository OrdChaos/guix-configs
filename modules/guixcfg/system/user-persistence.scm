;;; Selected user persistence（System owns）：/home/<user> 本身保持
;;; ephemeral（无状态 root），只有选定的用户数据位置经 bind mount
;;; 来自 /persist/data-home/<user>/。
;;;
;;; <persistent-user-dir> 对每个持久化条目记录两个相对位置：
;;;   backing   /persist/data-home/<user> 下的持久化数据位置
;;;   consumer  $HOME 下的挂载位置（均可嵌套）
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
  #:use-module (gnu services) ;simple-service
  #:use-module (gnu system file-systems) ;file-system
  #:use-module (guixcfg storage model) ;persist-mount-point（/persist 语义路径 authority）
  #:use-module (guixcfg utils home-path) ;ensure-home-parent-directories!
  #:use-module (guixcfg system mount-metadata) ;%persistent-home-mount-options
  #:use-module (guixcfg system persistence)
  #:use-module (guixcfg utils module-closure) ;guixcfg-module-select?
  #:use-module (guix gexp)
  #:use-module (guix modules) ;source-module-closure
  #:use-module (guix records)
  #:export (<persistent-user-dir> persistent-user-dir
                                  make-persistent-user-dir
                                  persistent-user-dir?
                                  persistent-user-dir-backing
                                  persistent-user-dir-consumer
                                  %persistent-user-dirs
                                  user-persistence-projections
            user-persistence-file-systems
                                  user-persistence-activation
                                  user-persistence-service))

;; 用户数据持久化条目：backing = /persist/data-home/<user> 相对；
;; consumer = $HOME 相对。
(define-record-type* <persistent-user-dir> persistent-user-dir
                     make-persistent-user-dir
  persistent-user-dir?
  (backing persistent-user-dir-backing) ;string
  (consumer persistent-user-dir-consumer))
; string

;; 持久化用户数据（XDG user directories 全集，与 (guixcfg home xdg)
;; 的 %xdg-user-dirs-service 对应——一致性由 tests/test-user-persistence.scm
;; 回归）+ Guix 相关 cache。仓库 checkout 是持久化 Projects
;; backing 下的普通子目录 Projects/guix-configs，不单独 bind。
;;
;; Guix channel cache（backing cache-guix → consumer $HOME/.cache/guix）：
;; `guix time-machine -C channels.lock.scm` 把各频道 git 仓库抓到
;; $XDG_CACHE_HOME/guix；无状态 /home 下每次 reconfigure 都要重新
;; clone 全部频道（guix 仓库最大，数分钟）。
;;
;; Guix channel cache 是唯一需要持久化的工具 cache。Rust toolchains are
;; direct references of the Home profile, so they have neither a runtime cache
;; nor indirect GC roots.  Consumer paths stay precise; never persist ~/.cache
;; （AGENT.md §12）。内容均可重建，不构成 canonical mutable state——是
;; docs/architecture/persistence.md "Projection exceptions" 第 4 条
;; （cache ephemeral）的显式例外。
;;
;; 明确不持久化 $HOME/.local/share/Trash（home trash）：GLib 的
;; g_local_file_trash 按 st_dev 把普通 HOME 文件判为 home trash
;; （$XDG_DATA_HOME/Trash）；该目录若被做成独立 bind mount，rename
;; 跨 mount → EXDEV，所有普通文件删除失败（2026-08 实测；GLib
;; 2.86 glocalfile.c）。home trash 随 ephemeral /home 每 boot 重建
;; 是符合无状态系统语义的正确行为（docs/architecture/home.md）。
(define %persistent-user-dirs
  (list (persistent-user-dir (backing "Projects")
                             (consumer "Projects"))
        (persistent-user-dir (backing "Desktop")
                             (consumer "Desktop"))
        (persistent-user-dir (backing "Documents")
                             (consumer "Documents"))
        (persistent-user-dir (backing "Downloads")
                             (consumer "Downloads"))
        (persistent-user-dir (backing "Music")
                             (consumer "Music"))
        (persistent-user-dir (backing "Pictures")
                             (consumer "Pictures"))
        (persistent-user-dir (backing "Public")
                             (consumer "Public"))
        (persistent-user-dir (backing "Templates")
                             (consumer "Templates"))
        (persistent-user-dir (backing "Videos")
                             (consumer "Videos"))
        ;; Guix channel checkout / profile cache（见上）。
        (persistent-user-dir (backing "cache-guix")
                             (consumer ".cache/guix"))))

(define (user-persistence-projections user)
  "Convert selected user directories to generic persistence projections.
The canonical backing lives below the data-home root and is owned by USER;
HOME itself is restored to 0700 ownership on activation."
  (let ((home (string-append "/home/" user))
        (root (persist-mount-point "@persist-data-home")))
    (map (lambda (d)
           (persistence-projection
             (name (string->symbol
                    (string-append "user-" (persistent-user-dir-backing d))))
             (root root)
             (backing (string-append user "/"
                                     (persistent-user-dir-backing d)))
             (consumer (string-append home "/"
                                      (persistent-user-dir-consumer d)))
             (exposure 'bind-directory)
             (owner 'user)
             (owner-user user)
             (mode #f)
             (options %persistent-home-mount-options)
             (home home)
             (home-mode #o700)
             (seeds '())))
         %persistent-user-dirs)))

(define (user-persistence-file-systems user)
  "持久化用户数据的 bind mount 声明，由通用 persistence executor 派生。"
  (persistence-set-file-systems
    (persistence-set (projections
                       (user-persistence-projections user)))))

(define (user-persistence-activation user)
  "activation gexp：由通用 persistence executor 建立 backing、HOME
中间层、consumer 挂载点，并把 /home/USER 恢复为 0700 user-owned。"
  (persistence-set-activation
    (persistence-set (projections
                       (user-persistence-projections user)))))

(define (user-persistence-service user)
  "把 selected user 持久化目录创建挂到系统 activation。"
  (persistence-set-service
    (persistence-set (projections
                       (user-persistence-projections user)))))
