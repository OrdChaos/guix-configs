;;; resolvconf-bootstrap：DNS 启动修复的静态图断言 + 真实执行 smoke。
;;;
;;; 覆盖（对应任务验收清单）：
;;;   RB1 bootstrap one-shot shepherd 服务存在于 %os
;;;   RB2 NetworkManager 显式依赖 resolvconf-bootstrap，且 pinned
;;;      service-type 自带的基础 requirements（user-processes /
;;;      dbus-system / loopback）没有丢失
;;;   RB3 host 层的 NM shepherd-requirement 精确等于
;;;      '(resolvconf-bootstrap)（wireless-daemon 的移除决策保持，
;;;      无其它意外项）
;;;   RB4 %os 的 etc-service 无静态 resolv.conf 条目（resolv.conf
;;;      不是仓库配置源）
;;;   RB5 %os 无任何 /etc/resolv.conf 或 /run/resolvconf 持久化
;;;      （file-systems bind 扫描 + application/machine-state 层）
;;;   RB6 bootstrap 调用的是 store 内锁定版 openresolv
;;;      （file-append），不是 PATH 里碰巧存在的 resolvconf
;;;   RB-E1..E5 真实执行（隔离 root + store 真实二进制）：
;;;      placeholder 接管（-u 备份 .bak 后覆盖）/ 缺失接管 /
;;;      symlink 不动 / 用户普通文件不动 / 已管理文件不动
;;;
;;; 由 tests/run-tests.scm 加载运行（提供 GUIX_CONFIG_FACTS 与
;;; nonguix/virelith/saayix load path）。

(use-modules (guixcfg system resolvconf)
             (guixcfg system application-persistence) ; RB5 accessor
             (guixcfg hosts vm)
             (guixcfg apps model)     ; applications-persistence（RB5）
             (guixcfg apps registry)  ; %applications（RB5）
             (gnu services)
             (gnu services shepherd)  ; shepherd-root-service-type、shepherd-service-*
             (gnu services networking) ; network-manager-service-type / configuration accessor
             (gnu services base)      ; etc-service-type
             (gnu system)             ; operating-system-*
             (gnu system file-systems) ; file-system-mount-point
             (guix store)             ; open-connection
             (guix monads)            ; run-with-store
             (guix derivations)       ; build-derivations、derivation->output-path
             (guix gexp)              ; lower-object
             (ice-9 rdelim)           ; read-line/read-string
             (ice-9 popen)            ; open-input-pipe
             (ice-9 textual-ports)
             (ice-9 ftw)              ; scandir
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; ── 图结构静态断言 ──────────────────────────────────────────
(define (folded-services type)
  (service-value (fold-services (operating-system-services %os)
                                #:target-type type)))

(define %shepherd-services
  (shepherd-configuration-services
   (folded-services shepherd-root-service-type)))

(define (svc-with-provision sym)
  (find (lambda (svc) (memq sym (shepherd-service-provision svc)))
        %shepherd-services))

(define (nm-config)
  (let ((svc (find (lambda (s)
                     (eq? (service-kind s) network-manager-service-type))
                   (operating-system-services %os))))
    (service-value svc)))

(test-begin "resolvconf-bootstrap")

;; RB1：bootstrap one-shot shepherd 服务存在。
(let ((svc (svc-with-provision 'resolvconf-bootstrap)))
  (test-assert "RB1: resolvconf-bootstrap shepherd service present in %os"
               svc)
  (test-assert "RB1: bootstrap is one-shot"
               (and svc (shepherd-service-one-shot? svc)))
  (test-assert "RB1: bootstrap does not respawn"
               (and svc (not (shepherd-service-respawn? svc))))
  (test-assert "RB1: bootstrap has no shepherd requirement"
               (and svc (null? (shepherd-service-requirement svc)))))

;; RB2：NetworkManager 依赖 bootstrap，基础 requirements 保留。
(let ((nm (svc-with-provision 'NetworkManager)))
  (test-assert "RB2: NetworkManager service present in %os"
               nm)
  (test-assert "RB2: NetworkManager requires resolvconf-bootstrap"
               (and nm (memq 'resolvconf-bootstrap
                             (shepherd-service-requirement nm))))
  (test-assert "RB2: pinned base requirements preserved \
(user-processes/dbus-system/loopback)"
               (and nm
                    (every (lambda (r)
                             (memq r (shepherd-service-requirement nm)))
                           '(user-processes dbus-system loopback)))))

;; RB3：host 层 NM 配置：只新增 bootstrap，wireless-daemon 移除
;; 决策保持（VM 无 WiFi，pinned 默认 '(wireless-daemon) 会 fail-fast）。
(test-assert "RB3: NM config shepherd-requirement is exactly \
(resolvconf-bootstrap)"
             (equal? '(resolvconf-bootstrap)
                     (network-manager-configuration-shepherd-requirement
                      (nm-config))))

;; RB4：etc-service 无静态 resolv.conf 条目。
(test-assert "RB4: no static resolv.conf in etc-service-type"
             (not (assoc "resolv.conf" (folded-services etc-service-type))))

;; RB5：无 /etc/resolv.conf 或 /run/resolvconf 持久化。
(test-assert "RB5: no bind persistence of /etc/resolv.conf or \
/run/resolvconf in %os file-systems"
             (let ((fss (operating-system-file-systems %os)))
               (not (any (lambda (fs)
                           (member (file-system-mount-point fs)
                                   '("/etc/resolv.conf" "/run/resolvconf")))
                         fss))))

(test-assert "RB5: application persistence has no resolv.conf rule"
             (let ((rules (applications-persistence %applications)))
               (not (any (lambda (rule)
                           (or (string-contains
                                (application-persistence-rule-backing rule)
                                "resolv.conf")
                               (string-contains
                                (application-persistence-rule-consumer rule)
                                "resolv.conf")))
                         rules))))

(test-assert "RB5: no machine-state persistence service in %os"
             (not (any (lambda (svc)
                         (eq? 'machine-state-persistence
                              (service-type-name (service-kind svc))))
                       (operating-system-services %os))))

;; ── RB6 + RB-E：真实构建与执行 ──────────────────────────────
(define %store (open-connection))

(define (build-thing thing)
  (let ((drv (run-with-store %store (lower-object thing))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define %bootstrap-program
  (build-thing (resolvconf-bootstrap-program)))

(define %bootstrap-script-text
  (call-with-input-file %bootstrap-program
                        (lambda (p) (read-string p))))

;; RB6：调用的是 store 内锁定版 openresolv，不是 PATH 解析。
(test-assert "RB6: built program references the store openresolv"
             (and (string-contains %bootstrap-script-text "/gnu/store/")
                  (string-contains %bootstrap-script-text "-openresolv-")
                  (string-contains %bootstrap-script-text
                                   "/sbin/resolvconf")))
(test-assert "RB6: source declares (file-append openresolv ...), \
never bare PATH invocation"
             (let ((s (call-with-input-file
                       "modules/guixcfg/system/resolvconf.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "(file-append openresolv \"/sbin/resolvconf\")")
                    (not (string-contains s "(system* \"resolvconf\""))
                    (not (string-contains s "(invoke \"resolvconf\"")))))

;; RB-E：隔离 root 里真实执行（unshare user+mount namespace，
;; bind /gnu/store，chroot；与 test-runtime-exec 同一基础设施）。
(define %guile
  ;; 已构建 artifact 的 shebang 里引用的 guile store 路径。
  (let* ((line (call-with-input-file %bootstrap-program
                                     (lambda (p) (read-line p)))))
    (and (string-prefix? "#!" line)
         (car (string-split (substring line 2) #\space)))))

(define (make-resolv-root setup)
  "SETUP 是 'placeholder | 'user-file | 'symlink | 'absent | 'managed。"
  (let ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                            "/guixcfg-resolvconf-" (number->string (getpid))
                            "-" (number->string (random 100000)))))
    (mkdir dir)
    (mkdir (string-append dir "/etc"))
    (mkdir (string-append dir "/gnu"))
    (mkdir (string-append dir "/gnu/store"))
    (mkdir (string-append dir "/dev")) ; resolvconf 脚本的 2>/dev/null 需要
    (case setup
      ((placeholder)
       (call-with-output-file (string-append dir "/etc/resolv.conf")
                              (lambda (p)
                                (display %guix-nscd-placeholder-content p))))
      ((user-file)
       (call-with-output-file (string-append dir "/etc/resolv.conf")
                              (lambda (p)
                                (display "nameserver 8.8.8.8\n" p))))
      ((symlink)
       (call-with-output-file (string-append dir "/etc/real-resolv.conf")
                              (lambda (p)
                                (display "nameserver 8.8.8.8\n" p)))
       (symlink "/etc/real-resolv.conf"
                (string-append dir "/etc/resolv.conf")))
      ((managed)
       (call-with-output-file (string-append dir "/etc/resolv.conf")
                              (lambda (p)
                                (display "# Generated by resolvconf\n\
nameserver 10.0.2.3\n" p)))))
    dir))

(define %coreutils-bin
  ;; resolvconf 脚本经 PATH 调用 mkdir/rm/cp/sleep（chroot 无 /bin）；
  ;; coreutils 本体已在 bind 的 /gnu/store 里，把其 bin 目录放进
  ;; chroot 进程的 PATH 即可。
  (let ((hits (scandir "/gnu/store"
                       (lambda (dir)
                         (string-contains dir "-coreutils-")))))
    (and (pair? hits)
         (string-append "/gnu/store/" (car hits) "/bin"))))

(define (run-bootstrap root)
  "在隔离 root 里执行 production bootstrap artifact；返回 exit code。
timeout 兜底（resolvconf 的锁循环在 PATH 缺 coreutils 时会无 sleep
busy-loop——曾实测挂死测试）。"
  (let ((script
         (string-append
          "unshare --user --map-root-user --map-users=auto --map-groups=auto "
          "--mount --pid --fork sh -c '"
          "PATH=" %coreutils-bin ":$PATH; "
          "mknod -m 666 " root "/dev/null c 1 3; "
          "mount --bind /gnu/store " root "/gnu/store; "
          "timeout 60 chroot " root " " %guile " --no-auto-compile "
          %bootstrap-program " >/dev/null 2>&1; "
          "echo $?'")))
    (let* ((pipe (open-input-pipe script))
           (out (get-string-all pipe)))
      (close-pipe pipe)
      (string->number (string-trim-both out)))))

(define (resolv-conf-first-line root)
  (let ((p (string-append root "/etc/resolv.conf")))
    (and (file-exists? p)
         (call-with-input-file p read-line))))

;; RB-E1：Guix nscd placeholder → -u 官方接管（备份 .bak 后覆盖）。
(let ((root (make-resolv-root 'placeholder)))
  (let ((code (run-bootstrap root)))
    (test-equal "RB-E1: placeholder bootstrapped, exits 0" 0 code)
    (test-equal "RB-E1: resolv.conf now openresolv-owned"
                "# Generated by resolvconf"
                (resolv-conf-first-line root))
    (test-assert "RB-E1: previous content preserved in resolv.conf.bak"
                 (let ((bak (string-append root "/etc/resolv.conf.bak")))
                   (and (file-exists? bak)
                        (string=? %guix-nscd-placeholder-content
                                  (call-with-input-file bak
                                                        (lambda (p)
                                                          (read-string p))))))))
  (false-if-exception (delete-file-recursively root)))

;; RB-E2：用户自定义普通文件 → 不触碰。
(let ((root (make-resolv-root 'user-file)))
  (let ((code (run-bootstrap root)))
    (test-equal "RB-E2: user file untouched, exits 0" 0 code)
    (test-equal "RB-E2: content unchanged"
                "nameserver 8.8.8.8\n"
                (call-with-input-file (string-append root "/etc/resolv.conf")
                                      (lambda (p) (read-string p))))
    (test-assert "RB-E2: no backup created"
                 (not (file-exists?
                       (string-append root "/etc/resolv.conf.bak")))))
  (false-if-exception (delete-file-recursively root)))

;; RB-E3：symlink（其它 manager / etc-service 形态）→ 不触碰。
(let ((root (make-resolv-root 'symlink)))
  (let ((code (run-bootstrap root)))
    (test-equal "RB-E3: symlink untouched, exits 0" 0 code)
    (test-eq "RB-E3: still a symlink"
             'symlink
             (stat:type (lstat (string-append root "/etc/resolv.conf"))))
    (test-equal "RB-E3: symlink target unchanged"
                "nameserver 8.8.8.8\n"
                (call-with-input-file
                 (string-append root "/etc/real-resolv.conf")
                 (lambda (p) (read-string p)))))
  (false-if-exception (delete-file-recursively root)))

;; RB-E4：文件缺失 → -u 直接建立 owned 文件（NM 的 -a 随后写入
;; nameserver）。
(let ((root (make-resolv-root 'absent)))
  (let ((code (run-bootstrap root)))
    (test-equal "RB-E4: missing file bootstrapped, exits 0" 0 code)
    (test-equal "RB-E4: resolv.conf created openresolv-owned"
                "# Generated by resolvconf"
                (resolv-conf-first-line root)))
  (false-if-exception (delete-file-recursively root)))

;; RB-E5：已由 openresolv 管理的文件 → 不触碰（内容含 nameserver
;; 时尤其不能动）。
(let ((root (make-resolv-root 'managed)))
  (let ((code (run-bootstrap root)))
    (test-equal "RB-E5: managed file untouched, exits 0" 0 code)
    (test-equal "RB-E5: content unchanged"
                "# Generated by resolvconf\nnameserver 10.0.2.3\n"
                (call-with-input-file (string-append root "/etc/resolv.conf")
                                      (lambda (p) (read-string p)))))
  (false-if-exception (delete-file-recursively root)))

(test-end "resolvconf-bootstrap")
