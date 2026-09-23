;;; Offline installer image helper（docs/operations/offline-iso.md）。
;;;
;;; 这里把“离线安装 ISO 需要携带什么”集中成一个可测试的组装函数：
;;;   - pinned channel profile（installer 内 guix time-machine 的
;;;     inferior cache 目标）；
;;;   - 仓库 snapshot（安装器直接可用，install 的 repo 阶段再复制到
;;;     目标持久 HOME）；
;;;   - 目标 System/Home closure（重活：kernel/firmware/Nonguix 包、
;;;     Home 生成闭包）；
;;;   - 激活期把 snapshot/channel-cache 种子投影到 LiveOS 的 guest/root
;;;     HOME 与 /var/guix/profiles/per-user/*/inferiors。
;;;
;;; 边界（有意不覆盖）：Flatpak OSTree、Mihomo provider、Noctalia
;;; plugins 是运行期在线数据/应用生命周期，不属于本 ISO 契约（
;;; docs/operations/offline-iso.md）。

(define-module (guixcfg images offline)
               #:use-module (gnu packages base) ; coreutils（payload chown）
               #:use-module (gnu services)      ; simple-service
               #:use-module (gnu services base) ; mingetty-service-type/configuration
               #:use-module (gnu services shepherd) ; shepherd-root-service-type、shepherd-service
               #:use-module (gnu system)        ; operating-system-with-gc-roots
               #:use-module (gnu system install) ; installation-os
               #:use-module (guix base32)       ; bytevector->base32-string
               #:use-module (guix channels)     ; channel-commit
               #:use-module (guix gexp)         ; local-file、file-like、program-file
               #:use-module (guixcfg utils repository-source) ; repository-root
               #:use-module (gcrypt hash)       ; sha256
               #:use-module (rnrs bytevectors)   ; string->utf8
               #:use-module (srfi srfi-1)       ; member
               #:export (channel-profile-cache-key
                         repository-snapshot
                         offline-installer-payload-program
                         offline-installer-skel-service
                         offline-installer-payload-service
                         offline-installation-os))

;;; ────────────────────────────────────────────────────────────
;;; channel inferior cache key

(define (channel-profile-cache-key channels)
  "CHANNELS（<channel> list）→ pinned Guix inferior cache key。算法必须与
pinned Guix (guix inferior) cached-channel-instance 的 key 完全一致：
base32(sha256(string-concatenate(map channel-commit CHANNELS)))——
time-machine 的 cache hit 只依赖 lock 中显式 channel commit 的连接，
不依赖 channel dependency 展开。"
  (bytevector->base32-string
   (sha256 (string->utf8
            (string-concatenate (map channel-commit channels))))))

;;; ────────────────────────────────────────────────────────────
;;; repository snapshot（repository 是 evaluation/deployment input）

(define %snapshot-excluded-top-level-entries
  '(".blue-store" ".zcode" "vms"))

(define (repository-snapshot)
  "完整仓库 checkout 的 recursive local-file（含 .git；排除本地构建/VM
运行时目录）。经 repository-root 的 marker resolver 解析，不依赖进程
CWD，也不在 generated runtime 读取 checkout。"
  (local-file (assume-source-relative-file-name (repository-root))
              "guix-configs"
              #:recursive? #t
              #:select? (lambda (file stat)
                          (not (member (basename file)
                                       %snapshot-excluded-top-level-entries)))))

;;; ────────────────────────────────────────────────────────────
;;; LiveOS payload：先 skel，再 Shepherd one-shot
;;;
;;; activation 阶段的 user service 先于 account-service 的
;;; guest/home 创建执行；第一版直接把仓库写到 /home/guest，会在
;;; guest 尚不存在时失败（activation 单项失败只 warning，系统仍
;;; 继续启动——2026-09 实机 ISO 实测）。这里改成两段：
;;;
;;;   1. activation 只复制仓库到 /etc/skel/guix-configs；账号创建
;;;      时由官方 copy-account-skeletons 复制进 /home/guest；
;;;   2. Shepherd one-shot 在 user-processes 后补最终路径、root
;;;      兼容链接与 guest/root inferior cache，并让 mingetty 等它，
;;;      避免登录提示早于 payload。

(define %installer-repository-path "/home/guest/guix-configs")
(define %installer-root-repository-link "/root/guix-configs")
(define %installer-skel-repository-path "/etc/skel/guix-configs")
(define %installer-payload-provision 'offline-installer-payload)

(define (offline-installer-payload-program repository
                                           channel-profile
                                           cache-key)
  "一次性 Shepherd program：guest 账号已存在后补最终仓库路径与
inferior caches。幂等，可重复执行。"
  (program-file
   "offline-installer-payload"
   #~(begin
      (define mkdir #$(file-append coreutils "/bin/mkdir"))
      (define rm #$(file-append coreutils "/bin/rm"))
      (define cp #$(file-append coreutils "/bin/cp"))
      (define chown-bin #$(file-append coreutils "/bin/chown"))
      
      (define (run . args)
        (unless (zero? (apply system* args))
          (error "offline installer command failed" args)))
      
      (define (remove-path! path)
        (let ((st (false-if-exception (lstat path))))
          (when st
            (if (eq? 'symlink (stat:type st))
              (delete-file path)
              (run rm "-rf" path)))))
      
      (define (seed-inferior-cache! user)
        (let ((pw (getpwnam user)))
          (unless pw
            (error "offline installer: unknown user" user))
          (let* ((uid (passwd:uid pw))
                 (gid (passwd:gid pw))
                 (user-dir (string-append "/var/guix/profiles/per-user/"
                                          user))
                 (cache-dir (string-append user-dir "/inferiors"))
                 (link (string-append cache-dir "/" #$cache-key))
                 (owner (string-append (number->string uid)
                                       ":"
                                       (number->string gid))))
            (run mkdir "-p" cache-dir)
            (chown user-dir uid gid)
            (chown cache-dir uid gid)
            (remove-path! link)
            (symlink #$channel-profile link)
            (run chown-bin "-h" owner link))))
      
      (let ((guest (getpwnam "guest")))
        (unless guest
          (error "offline installer: guest account missing"))
        ;; /etc/skel 已由 activation 写入；账号创建通常已复制。若
        ;; 该目录因 resume/manual activation 已存在而跳过 skeleton，
        ;; 这里幂等补齐。
        (unless (file-exists? #$%installer-repository-path)
          (run cp "-a" #$repository #$%installer-repository-path))
        (chmod #$%installer-repository-path #o755)
        (run chown-bin
             "-R"
             (string-append (number->string (passwd:uid guest))
                            ":"
                            (number->string (passwd:gid guest)))
             #$%installer-repository-path)
        (remove-path! #$%installer-root-repository-link)
        (symlink #$%installer-repository-path
                 #$%installer-root-repository-link))
      
      (seed-inferior-cache! "guest")
      (seed-inferior-cache! "root")
      0)))

(define* (offline-installer-skel-service repository
                                         channel-profile
                                         cache-key)
         "Activation service：把仓库复制到 /etc/skel（guest 账号随后由官方
account activation 复制）并预置 root inferior cache。不依赖 guest 账号
已存在。"
         (simple-service 'offline-installer-skel
                         activation-service-type
                         #~(begin
                            (define mkdir #$(file-append coreutils "/bin/mkdir"))
                            (define rm #$(file-append coreutils "/bin/rm"))
                            (define cp #$(file-append coreutils "/bin/cp"))
                            (define chown-bin #$(file-append coreutils "/bin/chown"))
                            
                            (define (run . args)
                              (unless (zero? (apply system* args))
                                (error "offline installer command failed" args)))
                            
                            (define (remove-path! path)
                              (let ((st (false-if-exception (lstat path))))
                                (when st
                                  (if (eq? 'symlink (stat:type st))
                                    (delete-file path)
                                    (run rm "-rf" path)))))
                            
                            (define (seed-root-inferior-cache!)
                              (let* ((link (string-append
                                            "/var/guix/profiles/per-user/root/inferiors/"
                                            #$cache-key)))
                                (run mkdir "-p" (dirname link))
                                (remove-path! link)
                                (symlink #$channel-profile link)
                                (run chown-bin "-h" "0:0" link)))
                            
                            (run mkdir "-p" "/etc/skel")
                            (remove-path! #$%installer-skel-repository-path)
                            (run cp "-a" #$repository
                                 #$%installer-skel-repository-path)
                            (chmod #$%installer-skel-repository-path #o755)
                            (seed-root-inferior-cache!))))

(define* (offline-installer-payload-service repository
                                            channel-profile
                                            cache-key)
         "Shepherd one-shot：账号/home 创建后补最终仓库路径与 guest/root
inferior caches；mingetty 的 shepherd requirement 会等待本服务。"
         (let ((program (offline-installer-payload-program repository
                                                           channel-profile
                                                           cache-key)))
           (simple-service
            %installer-payload-provision
            shepherd-root-service-type
            (list (shepherd-service
                   (provision (list %installer-payload-provision))
                   (requirement '(user-processes virtual-terminal))
                   (one-shot? #t)
                   (respawn? #f)
                   (documentation "Seed the offline installer repository and pinned channel caches.")
                   (start #~(lambda () (zero? (system* #$program))))
                   (stop #~(const #f)))))))

(define (offline-installer-login-gating services)
  "让文本登录 mingetty 等待 offline-installer-payload one-shot，
避免登录提示早于仓库/cache 种子。"
  (map (lambda (svc)
         (if (and (eq? (service-kind svc) mingetty-service-type)
                  (mingetty-configuration? (service-value svc)))
           (let ((config (service-value svc)))
             (service
              mingetty-service-type
              (mingetty-configuration
               (inherit config)
               (shepherd-requirement
                (cons %installer-payload-provision
                      (mingetty-configuration-shepherd-requirement config))))))
           svc))
       services))

;;; ────────────────────────────────────────────────────────────
;;; installation OS assembly

(define* (offline-installation-os target-os
                                  #:key
                                  channel-profile
                                  repository
                                  cache-key
                                  (extra-packages '()))
         "TARGET-OS + CHANNEL-PROFILE + REPOSITORY 作为 official installation OS
的额外 GC roots；EXTRA-PACKAGES 进入 installer system profile。返回可
直接作为 `guix system image -t iso9660 FILE` 最后表达式的 OS。"
         (let* ((with-roots
                 (operating-system-with-gc-roots
                  installation-os
                  (list target-os channel-profile repository)))
                (skel
                 (offline-installer-skel-service repository
                                                 channel-profile
                                                 cache-key))
                (payload
                 (offline-installer-payload-service repository
                                                    channel-profile
                                                    cache-key)))
           (operating-system
            (inherit with-roots)
            (packages (append extra-packages
                              (operating-system-packages with-roots)))
            (services
             (offline-installer-login-gating
              (cons* skel
                     payload
                     (operating-system-user-services with-roots)))))))
