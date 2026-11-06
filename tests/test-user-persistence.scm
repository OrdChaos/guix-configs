;;; Selected user persistence 测试：/home/<user> 保持 ephemeral，
;;; 选定用户数据位置经 bind mount 来自 /persist/data-home/<user>/；
;;; activation 确保 backing 存在与 ownership（含嵌套 consumer 的
;;; HOME 侧中间层 owner 归还）。

(use-modules (gnu system file-systems)
             (guixcfg system persistence)
             (guix gexp)
             (guixcfg system user-persistence)
             (guixcfg system mount-metadata) ;%persistent-home-mount-options
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "user-persistence")

(define fss
  (user-persistence-file-systems "user"))

(test-equal "selected dirs declared"
            (map persistent-user-dir-consumer %persistent-user-dirs)
            (map (lambda (fs)
                   (string-drop (file-system-mount-point fs)
                                (string-length "/home/user/"))) fss))

(for-each (lambda (d)
            (let ((fs (find (lambda (fs)
                              (string=? (file-system-mount-point fs)
                                        (string-append "/home/user/"
                                                       (persistent-user-dir-consumer
                                                        d)))) fss)))
              (test-assert (string-append "/home/user/"
                                          (persistent-user-dir-consumer d)
                                          " bind mount declared")
                           (and fs
                                (string=? (file-system-device fs)
                                          (string-append
                                           "/persist/data-home/user/"
                                           (persistent-user-dir-backing d)))
                                (string=? (file-system-type fs) "none")
                                (member 'bind-mount
                                        (file-system-flags fs))
                                (string=? (file-system-options fs)
                                          %persistent-home-mount-options)
                                (file-system-create-mount-point? fs)))))
          %persistent-user-dirs)

(test-assert "all mount points under /home/user (HOME not fully persisted)"
             (every (lambda (fs)
                      (string-prefix? "/home/user/"
                                      (file-system-mount-point fs))) fss))
;; ── XDG user directories 全集覆盖（与 (guixcfg home xdg) 对应）──
(test-assert "repository has no dedicated persistence entry"
             (not (any (lambda (d)
                         (or (member (persistent-user-dir-backing d)
                                     '("guix-configs" "Projects/guix-configs"))
                             (member (persistent-user-dir-consumer d)
                                     '("guix-configs" "Projects/guix-configs"))))
                       %persistent-user-dirs)))

(test-assert "Projects is the repository's only persistence mount"
             (and (find (lambda (fs)
                          (string=? "/home/user/Projects"
                                    (file-system-mount-point fs))) fss)
                  (not (any (lambda (fs)
                              (member (file-system-mount-point fs)
                                      '("/home/user/guix-configs"
                                        "/home/user/Projects/guix-configs")))
                            fss))))

;; ── Guix cache 持久化（精确到单个目录，绝不持久化整个 ~/.cache）──
(test-assert "guix channel cache is persisted at ~/.cache/guix"
             (let ((d (find (lambda (d)
                              (string=? ".cache/guix"
                                        (persistent-user-dir-consumer d)))
                            %persistent-user-dirs)))
               (and d
                    (string=? "cache-guix"
                              (persistent-user-dir-backing d)))))

(test-assert "Rust toolchains do not create a persisted runtime cache"
             (not (any (lambda (d)
                         (string=? ".cache/guix-rust-toolchain"
                                   (persistent-user-dir-consumer d)))
                       %persistent-user-dirs)))

(test-assert "whole ~/.cache is NOT persisted"
             (not (any (lambda (d)
                         (string=? ".cache"
                                   (persistent-user-dir-consumer d)))
                       %persistent-user-dirs)))

;; ── home trash 不持久化（GLib 实证：独立 mount 破坏普通 HOME
;;    文件的 trash——st_dev 判定走 home trash，rename 跨 mount
;;    EXDEV；docs/architecture/home.md）────────────────────────
(test-assert "home trash is NOT persisted (independent mount breaks trash)"
             (not (any (lambda (d)
                         (string=? ".local/share/Trash"
                                   (persistent-user-dir-consumer d)))
                       %persistent-user-dirs)))
;; activation gexp 可编译
(test-assert "persistence activation gexp compiles"
             (and (gexp->script "user-persistence-check"
                                (user-persistence-activation "user")) #t))

;; Generic projection carries HOME ownership/mode and HOME-relative
;; consumer facts; the shared operation itself is exercised by the generic
;; persistence projection test and by the executor at runtime.
(test-assert "projection restores home with 0700 user ownership"
             (let ((p (car (user-persistence-projections "user"))))
               (and (string=? "/home/user"
                              (persistence-projection-home p))
                    (= #o700 (persistence-projection-home-mode p))
                    (eq? 'user (persistence-projection-owner p))
                    (string=? "user"
                              (persistence-projection-owner-user p)))))
(test-assert "projection consumer is resolved under home"
             (let ((p (car (user-persistence-projections "user"))))
               (string-prefix? "/home/user/"
                               (persistence-projection-consumer p))))
;; Guix Home 环境跨重启由官方 guix-home-service-type 恢复（见
;; test-home.scm 的绑定断言），本模块不持久化任何 Home 生成物。

(test-end "user-persistence")
