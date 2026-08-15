;;; Selected user persistence 测试：/home/<user> 保持 ephemeral，
;;; 选定目录经 bind mount 来自 /persist/data-home/<user>/；
;;; activation 确保目录存在与 ownership。

(use-modules (gnu system file-systems)
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

(test-end "user-persistence")
