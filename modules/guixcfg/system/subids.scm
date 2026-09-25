;;; Subordinate UID/GID ranges：rootless user namespace 的声明式基础设施。
;;;
;;; 背景：tests/test-runtime-exec.scm 与 tests/test-mixed-authority.scm
;;; 用 unshare --user --map-users=auto 在隔离 root 执行 generated
;;; artifacts。--map-users=auto 需要：
;;;   1. /etc/subuid + /etc/subgid 中本用户的 subordinate 段
;;;      （official subids-service-type，gnu system shadow）；
;;;   2. setuid 的 newuidmap/newgidmap（shadow 包；非 root 写多段
;;;      uid_map/gid_map 只能经它们）。
;;; 仓库此前从未声明这两项——旧机器上测试能过纯属宿主遗留状态
;;; （历史教训：2026-09 全新安装后声明式 /etc 不再含它们，Level 3
;;; 测试全部 EINVAL/ENOENT）。此处使其成为系统配置的一等事实。

(define-module (guixcfg system subids)
               #:use-module (gnu services)          ; service、simple-service、privileged-program-service-type
               #:use-module (gnu system shadow)     ; subids-service-type、subids-configuration
               #:use-module (gnu system accounts)   ; subid-range
               #:use-module (gnu system privilege)  ; privileged-program
               #:use-module (gnu packages admin)    ; shadow（newuidmap/newgidmap）
               #:use-module (guix gexp)             ; file-append
               #:use-module (guixcfg users facts)   ; %primary-user
               #:export (%subids-services))

;; %subordinate-id-min（(gnu build accounts)，100000）起的第一个 65536
;; 段由 subids-service 的 add-root? 默认行为自动分给 root；primary user
;; 显式取紧随其后的段，避免与自动 root 段重叠。
(define %primary-user-subid-start 165536)

(define %primary-user-subid-range
  (subid-range
   (name (user-profile-name %primary-user))
   (start %primary-user-subid-start)))

(define %subids-services
  (list (service subids-service-type
                 (subids-configuration
                  (subuids (list %primary-user-subid-range))
                  (subgids (list %primary-user-subid-range))))
        (simple-service 'newuidmap-privileged
                        privileged-program-service-type
                        (list (privileged-program
                               (program (file-append shadow "/bin/newuidmap"))
                               (setuid? #t))
                              (privileged-program
                               (program (file-append shadow "/bin/newgidmap"))
                               (setuid? #t))))))
