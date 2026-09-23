;;; Offline installer image helper 测试（docs/operations/offline-iso.md）：
;;;   - pinned inferior cache key 与 Guix cached-channel-instance 算法兼容；
;;;   - offline installation OS 确实把 target/channel-profile/repository
;;;     注册为 GC roots；
;;;   - repository skeleton 经 activation 写入，最终 payload 是
;;;     Shepherd one-shot，且 mingetty 等待 payload 后再出登录提示。
;;;
;;; 结构测试不构建 image、不触发 package derivation；payload smoke 只构建并
;;; 执行小型 program-file，验证 generated runtime 无隐式模块依赖。

(use-modules (guixcfg images offline)
             (guix channels)
             (guix derivations)          ; build-derivations、derivation->output-path
             (guix gexp)                 ; plain-file、file-union
             (guix monads)               ; run-with-store
             (guix packages)             ; package-name
             (guix store)                ; open-connection
             (gnu services)              ; service-kind、service-value
             (gnu services base)         ; mingetty-service-type/configuration
             (gnu services shepherd)     ; shepherd-root-service-type
             (gnu system)                ; operating-system?
             (gnu system install)        ; installation-os
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "offline-image")

(define %one-commit
  (channel
   (name 'guix)
   (url "https://example.invalid/guix.git")
   (commit "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")))

(test-equal "one-channel cache key matches pinned Guix key algorithm"
            ;; base32(sha256(commit-string))，由 gcrypt+base32 独立求得。
            "vcxg43xjfgv6uox47rjfrsgm234fe47a2rrg2jwhe6pteuhxpsha"
            (channel-profile-cache-key (list %one-commit)))

(test-equal "cache key changes with channel order"
            #f
            (equal? (channel-profile-cache-key
                     (list (channel (inherit %one-commit) (name 'one))
                           (channel (inherit %one-commit)
                                    (name 'two)
                                    (commit "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))))
                    (channel-profile-cache-key
                     (list (channel (inherit %one-commit)
                                    (name 'two)
                                    (commit "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                           (channel (inherit %one-commit) (name 'one))))))

(define %target-root (plain-file "target-system" "target"))
(define %channel-root (plain-file "channel-profile" "profile"))
(define %repository-root (plain-file "repository" "repo"))

(define %installer-os
  (offline-installation-os %target-root
                           #:channel-profile %channel-root
                           #:repository %repository-root
                           #:cache-key "cache-key"
                           #:extra-packages '()))

(test-assert "offline installation OS is an operating system"
             (operating-system? %installer-os))

;; simple-service 返回包装 service-type：按 extension target 判定
;; （tests/test-flatpak-service.scm 同款模式）。
(define (service-extends? svc target-type)
  (any (lambda (ext)
         (eq? (service-extension-target ext) target-type))
       (service-type-extensions (service-kind svc))))

(define %installer-roots
  (append-map service-value
              (filter (lambda (service)
                        (service-extends? service
                                          gc-root-service-type))
                      (operating-system-user-services %installer-os))))

(test-assert "offline installation roots retain target, channel profile and repository"
             (every (lambda (root)
                      (member root %installer-roots))
                    (list %target-root
                          %channel-root
                          %repository-root)))

(test-assert "offline repository skeleton activation service is present"
             (find (lambda (service)
                     (service-extends? service
                                       activation-service-type))
                   (operating-system-user-services %installer-os)))

(test-assert "offline payload is a shepherd one-shot service"
             (find (lambda (service)
                     (service-extends? service
                                       shepherd-root-service-type))
                   (operating-system-user-services %installer-os)))

(define %installer-mingetty
  (find (lambda (service)
          (eq? (service-kind service)
               mingetty-service-type))
        (operating-system-user-services %installer-os)))

(test-assert "mingetty login waits for the offline installer payload"
             (and %installer-mingetty
                  (member 'offline-installer-payload
                          (mingetty-configuration-shepherd-requirement
                           (service-value %installer-mingetty)))))

(test-assert "offline installer starts from the official installation OS packages"
             (let ((package-names (map package-name
                                       (operating-system-packages %installer-os))))
               (every (lambda (package)
                        (member (package-name package) package-names))
                      (operating-system-packages installation-os))))

;;; 真实执行 smoke：program-file 的外层 import 不会进入 generated
;;; runtime；(ice-9 posix) 这类不存在的模块曾导致 Shepherd one-shot
;;; 启动即失败、/home/guest/guix-configs 缺失。这里在隔离 root 中执行
;;; 实际 payload program，验证 guest/root cache 与仓库复制完整完成。
(define %store (open-connection))

(define (build-thing thing)
  (let ((drv (run-with-store %store (lower-object thing))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define %payload-repository
  (file-union "offline-payload-repository"
              `(("channels.lock.scm"
                 ,(plain-file "channels.lock.scm" "()\n"))
                ("modules/guixcfg/init.scm"
                 ,(plain-file "init.scm" ";; offline payload test\n")))))

(define %payload-channel-profile
  (plain-file "offline-payload-channel-profile" "profile\n"))

(define %payload-channel-profile-path
  (run-with-store %store (lower-object %payload-channel-profile)))

(define %payload-program
  (build-thing
   (offline-installer-payload-program %payload-repository
                                      %payload-channel-profile
                                      "cache-key")))

(define (make-offline-fake-root)
  (let ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                            "/guixcfg-offline-payload-"
                            (number->string (getpid))
                            "-"
                            (number->string (random 100000)))))
    (mkdir dir)
    (mkdir (string-append dir "/etc"))
    (mkdir (string-append dir "/gnu"))
    (mkdir (string-append dir "/gnu/store"))
    (mkdir (string-append dir "/home"))
    (mkdir (string-append dir "/home/guest"))
    (mkdir (string-append dir "/root"))
    (mkdir (string-append dir "/var"))
    (mkdir (string-append dir "/var/guix"))
    (mkdir (string-append dir "/var/guix/profiles"))
    (mkdir (string-append dir "/var/guix/profiles/per-user"))
    (call-with-output-file (string-append dir "/etc/passwd")
      (lambda (port)
        (display "root:x:0:0:root:/root:/bin/sh\n\
guest:x:1000:1000:guest:/home/guest:/bin/sh\n" port)))
    (call-with-output-file (string-append dir "/etc/nsswitch.conf")
      (lambda (port)
        (display "passwd: files\ngroup: files\n" port)))
    dir))

(define (run-offline-payload program fake-root)
  (let* ((pipe (open-input-pipe
                (string-append
                 "unshare --user --map-root-user --map-users=auto "
                 "--map-groups=auto --mount --pid --fork sh -c '"
                 "mount --bind /gnu/store " fake-root "/gnu/store; "
                 "chroot " fake-root " " program
                 " >/dev/null 2>&1; echo $?'")))
         (out (get-string-all pipe)))
    (close-pipe pipe)
    (string->number (string-trim-both out))))

(let ((root (make-offline-fake-root)))
  (test-equal "offline installer payload program executes to completion"
              0
              (run-offline-payload %payload-program root))
  (test-assert "offline payload copies the repository for guest"
               (file-exists?
                (string-append root
                               "/home/guest/guix-configs/channels.lock.scm")))
  (test-assert "offline payload exposes the repository to root"
               (string=? "/home/guest/guix-configs"
                         (readlink (string-append root "/root/guix-configs"))))
  (test-assert "offline payload seeds guest and root inferior caches"
               (every (lambda (user)
                        (string=? %payload-channel-profile-path
                                  (readlink
                                   (string-append root
                                                  "/var/guix/profiles/per-user/"
                                                  user
                                                  "/inferiors/cache-key"))))
                      '("guest" "root"))))

(test-end "offline-image")
