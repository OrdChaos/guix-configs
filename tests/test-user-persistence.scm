;;; Selected user persistence 测试：/home/<user> 保持 ephemeral，
;;; 选定目录经 bind mount 来自 /persist/data-home/<user>/；
;;; activation 确保目录存在与 ownership。

(use-modules (gnu services shepherd)    ; shepherd-service 访问器
             (gnu system file-systems)
             (guix gexp)
             (guixcfg system user-persistence)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "user-persistence")

(define fss (user-persistence-file-systems "user"))

(test-equal "selected dirs declared"
            %persistent-user-dirs
            (map (lambda (fs) (basename (file-system-mount-point fs))) fss))

(for-each
 (lambda (d)
   (let ((fs (find (lambda (fs)
                     (string=? (file-system-mount-point fs)
                               (string-append "/home/user/" d)))
                   fss)))
     (test-assert (string-append "/home/user/" d " bind mount declared")
                  (and fs
                       (string=? (file-system-device fs)
                                 (string-append "/persist/data-home/user/" d))
                       (string=? (file-system-type fs) "none")
                       (member 'bind-mount (file-system-flags fs))
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

;; ── Guix Home 环境跨重启重放 ──────────────────────────────────
;; guix home 内容全在 persist（/gnu/store + /var/guix），$HOME 只有
;; 符号链接；home-env-reapply 在 file-systems 就位后重建它们。
(define reapply-svc-val
  (service-value (home-env-reapply-service "user")))
(define reapply-shepherd
  (car reapply-svc-val))

(test-assert "home-env-reapply service registered"
  (member 'home-env-reapply (shepherd-service-provision reapply-shepherd)))

(test-assert "home-env-reapply requires file-systems (before login)"
  (member 'file-systems (shepherd-service-requirement reapply-shepherd)))

(test-assert "home-env-reapply is one-shot"
  (shepherd-service-one-shot? reapply-shepherd))

(test-assert "home-env-reapply program compiles"
  (let ((s (object->string
            (program-file-gexp (home-env-reapply-program "user")))))
    (and (string-contains s "/var/guix/profiles/per-user/")
         (string-contains s "/guix-home")
         (string-contains s ".guix-home")
         (string-contains s "symlink"))))

(test-end "user-persistence")
