;;; Gaming host infrastructure：游戏相关、不属于任何单一应用的
;;; host-level system 集成（Steam 是全局用户软件，controller udev
;;; rules 与游戏库目录 activation 对所有 host 一致，由
;;; (guixcfg hosts common) 组装进 system services）。
;;;
;;; 归属决策（2026-09，Steam 全线 Flatpak 化后）：
;;;   - steam-devices udev rules：手柄/VR 设备权限（pinned
;;;     gnu packages games 的 steam-devices-udev-rules）。Nonguix
;;;     容器时代它随 steam app 走；Flatpak Steam 的 controller
;;;     支持同样依赖宿主 udev rules（flathub steam wiki）——它是
;;;     机器能力（有没有手柄），不是某个 launcher 的属性；
;;;   - 游戏库目录 /persist/data-nobackup/{steam,aagl}：direct-access
;;;     bulk storage（docs/architecture/persistence.md（
;;;     data-nobackup）），经各自 Flatpak 的 managed override
;;;     （filesystem）暴露进 sandbox（路径 authority 在本模块，
;;;     definition 引用，不重复拼写）。目录必须预先存在且归 USER
;;;     （launcher 选择目录需要可写路径）——activation 创建 + chown
;;;     （noctalia-greeter backing ownership 同款模式：owner 经
;;;     /etc/passwd 运行时解析，不硬编码 uid/gid）。
;;;
;;; NVIDIA PRIME offload 变量不在此投影——Flatpak managed override
;;; 的环境差异由 %flatpak-prime-environment-overrides 在 host Guix
;;; Home 追加（(guixcfg system graphics nvidia) 单一 authority）。

(define-module (guixcfg system gaming)
               #:use-module (gnu packages games)   ; steam-devices-udev-rules
               #:use-module (gnu services)         ; simple-service
               #:use-module (gnu services base)    ; udev-rules-service、activation-service-type
               #:use-module (guix gexp)            ; with-imported-modules
               #:use-module (guix modules)         ; source-module-closure
               #:use-module (guixcfg storage model) ; persist-mount-point
               #:use-module (guixcfg users user)    ; %primary-user（owner 推导）
                #:export (%steam-games-library-path
                          %aagl-games-library-path
                          %gaming-system-services))

;; 游戏库 canonical 位置：/persist/data-nobackup/steam（persist-
;; mount-point 是 /persist/* 语义路径唯一 authority——AGENT.md §13）。
(define %steam-games-library-path
  (string-append (persist-mount-point "@persist-data-nobackup") "/steam"))

(define %aagl-games-library-path
  (string-append (persist-mount-point "@persist-data-nobackup") "/aagl"))

;; 游戏库目录 activation：mkdir + 归还 USER（幂等，不触碰已存在
;; 内容）。account projection 先于 activation 写 /etc/passwd。
(define (gaming-libraries-activation)
  (with-imported-modules (source-module-closure
                          '((gnu build accounts)   ; read-passwd、password-entry-*
                                                   (guix build utils)
                                                   (srfi srfi-1)))        ; find
                         #~(begin
                            (use-modules (gnu build accounts)
                                         (guix build utils)
                                         (srfi srfi-1))
                             (let* ((user-name #$(user-profile-name %primary-user))
                                    (user (find (lambda (entry)
                                                  (string=? (password-entry-name entry)
                                                            user-name))
                                                (read-passwd "/etc/passwd"))))
                               (unless user
                                 (error "gaming: games library owner account missing \
from /etc/passwd" user-name))
                               (for-each
                                (lambda (dir)
                                  (let ((existing (false-if-exception (lstat dir))))
                                    (when (and existing
                                               (not (eq? 'directory (stat:type existing))))
                                      (error "gaming: games library path exists but is not a directory"
                                             dir))
                                    (unless existing
                                      (mkdir-p dir)))
                                  (chown dir (password-entry-uid user) (password-entry-gid user))
                                  ;; 游戏库仅 primary user 可遍历。
                                  (chmod dir #o700))
                                (list #$%steam-games-library-path
                                      #$%aagl-games-library-path))
                               #t))))

;; gaming system services：controller udev rules + 游戏库目录
;; activation（所有 host 共享）。
(define %gaming-system-services
  (list (udev-rules-service 'steam-devices steam-devices-udev-rules)
        (simple-service 'gaming-library-directories
                        activation-service-type
                        (gaming-libraries-activation))))
