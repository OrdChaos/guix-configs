;;; Selected user persistence 测试：/home/<user> 保持 ephemeral，
;;; 选定用户数据位置经 bind mount 来自 /persist/data-home/<user>/；
;;; activation 确保 backing 存在与 ownership（含嵌套 consumer 的
;;; HOME 侧中间层 owner 归还）。

(use-modules (gnu system file-systems)
             (guix gexp)
             (guixcfg system user-persistence)
             (guixcfg system mount-metadata) ; %persistent-home-mount-options
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "user-persistence")

(define fss (user-persistence-file-systems "user"))

(test-equal "selected dirs declared"
            (map persistent-user-dir-consumer %persistent-user-dirs)
            (map (lambda (fs)
                   (string-drop (file-system-mount-point fs)
                                (string-length "/home/user/")))
                 fss))

(for-each
 (lambda (d)
   (let ((fs (find (lambda (fs)
                     (string=? (file-system-mount-point fs)
                               (string-append
                                "/home/user/"
                                (persistent-user-dir-consumer d))))
                   fss)))
     (test-assert (string-append
                   "/home/user/" (persistent-user-dir-consumer d)
                   " bind mount declared")
                  (and fs
                       (string=? (file-system-device fs)
                                 (string-append
                                  "/persist/data-home/user/"
                                  (persistent-user-dir-backing d)))
                       (string=? (file-system-type fs) "none")
                       (member 'bind-mount (file-system-flags fs))
                       (string=? (file-system-options fs)
                                 %persistent-home-mount-options)
                       (file-system-create-mount-point? fs)))))
 %persistent-user-dirs)

(test-assert "all mount points under /home/user (HOME not fully persisted)"
             (every (lambda (fs)
                      (string-prefix? "/home/user/" (file-system-mount-point fs)))
                    fss))
(test-assert "no mount point is /home/user itself"
             (not (any (lambda (fs)
                         (string=? (file-system-mount-point fs) "/home/user"))
                       fss)))

;; ── XDG user directories 全集覆盖（与 (guixcfg home xdg) 对应）──
(test-assert "persistent dirs cover the XDG user directory set"
             (every (lambda (d)
                      (member d (map persistent-user-dir-consumer
                                     %persistent-user-dirs)))
                    '("Desktop" "Documents" "Downloads" "Music"
                      "Pictures" "Projects" "Public" "Templates"
                      "Videos")))

;; ── home trash 不持久化（GLib 实证：独立 mount 破坏普通 HOME
;;    文件的 trash——st_dev 判定走 home trash，rename 跨 mount
;;    EXDEV；docs/architecture/home.md）────────────────────────
(test-assert "home trash is NOT persisted (independent mount breaks trash)"
             (not (any (lambda (d)
                         (string=? ".local/share/Trash"
                                   (persistent-user-dir-consumer d)))
                       %persistent-user-dirs)))
(test-assert "no trash bind mount declared"
             (not (any (lambda (fs)
                         (string=? "/home/user/.local/share/Trash"
                                   (file-system-mount-point fs)))
                       fss)))

;; activation gexp 可编译
(test-assert "persistence activation gexp compiles"
             (and (gexp->script "user-persistence-check"
                                (user-persistence-activation "user"))
                  #t))

;; /home/user 自身 ownership 恢复（file-systems 挂载点创建会以 root
;; 建出 home，guix activate-user-home 对已存在 home 跳过——由本
;; activation 恢复 0700 + 用户所有）。<gexp> 的 printer 会打印 body。
(test-assert "activation restores /home/user ownership"
             (let ((s (object->string (user-persistence-activation "user"))))
               (and (string-contains s "/home/")
                    (string-contains s "chown")
                    (string-contains s "chmod"))))

;; 嵌套 consumer 的 HOME 侧中间父目录 owner 归还走共享原语
;; (guixcfg utils home-path)（当前无嵌套 consumer——Trash 已按实证
;; 移除；机制保留，未来嵌套 consumer 直接复用）。
(test-assert "activation uses the shared home-parent ownership primitive"
             (let ((s (object->string (user-persistence-activation "user"))))
               (string-contains s "ensure-home-parent-directories!")))

;; Guix Home 环境跨重启由官方 guix-home-service-type 恢复（见
;; test-home.scm 的绑定断言），本模块不持久化任何 Home 生成物。

(test-end "user-persistence")
