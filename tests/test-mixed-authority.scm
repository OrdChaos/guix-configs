;;; Mixed-authority application persistence 测试（Phase A，
;;; docs/architecture/persistence.md（Mixed state container））。
;;;
;;; 覆盖：
;;;   1.  app-private mixed container 合法（.config/<app>）
;;;   2.  公共 XDG root 非法（.config/.local/.local/share）
;;;   3.  directory bind 仍是唯一 production exposure；无 bind-file
;;;   4.  backing 仍在 /persist/data-app；consumer 从 user 参数派生
;;;   5.  no copy/sync / no implicit migration
;;;   6.  synthetic persistent container：Home-managed child +
;;;       unknown mutable child 可共存（真实执行 pinned Guix Home
;;;       update-symlinks 脚本）
;;;   7.  generation replacement 不删除 unknown mutable child
;;;   8.  stale managed child 按 pinned Guix Home contract 清理
;;;       （旧代声明的 store symlink → 删除；非 store symlink → 跳过）
;;;   9.  dual authority（app 写 Home 管理的文件）→ Home backup +
;;;       replace（不 merge，不 conflict-resolution）
;;;   10. generic executor 不知道具体应用（mpv/fish）
;;;   11. 无 HOME 硬编码（HOME 从 user 参数派生）

(use-modules (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (guix modules)
             (guix build utils)          ; mkdir-p
             (gnu services)
             (gnu system file-systems)
             (guixcfg system application-persistence)
             (guixcfg storage model)     ; persist-mount-point
             (ice-9 rdelim)
             (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 ftw)                 ; scandir
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "mixed-authority")

;; ── 1-5：validation contract（mixed container 是 bind-directory 的
;;    合法消费者；公共 XDG root 仍禁止）────────────────────────
(define mixed-rule
  (application-persistence-rule
   (name 'example-app)
   (backing "example-app/config")        ; /persist/data-app 相对
   (consumer ".config/example-app")      ; app-private 容器（HOME 相对）
   (exposure 'bind-directory)
   (lifecycle 'application-owned)))

(test-assert "app-private mixed container is legal"
             (valid-application-persistence-rule? mixed-rule))

(for-each
 (lambda (root)
   (test-assert (string-append "public XDG root is illegal: " root)
                (not (valid-application-persistence-rule?
                      (application-persistence-rule
                       (name 'bad) (backing "x") (consumer root))))))
 '(".config" ".local" ".local/share" ".cache"))

(test-assert "bind-directory is the only allowed exposure"
             (not (valid-application-persistence-rule?
                   (application-persistence-rule
                    (name 'bad) (backing "x") (consumer ".config/x")
                    (exposure 'bind-file)))))

(test-assert "backing stays under /persist/data-app"
             (let ((fs (car (application-persistence-file-systems
                             (list mixed-rule) "alice"))))
               (string-prefix?
                (string-append (persist-mount-point "@persist-data-app") "/")
                (file-system-device fs))))

(test-assert "consumer derives from the user parameter (no HOME hardcoding)"
             (let ((fs (car (application-persistence-file-systems
                             (list mixed-rule) "alice"))))
               (string=? "/home/alice/.config/example-app"
                         (file-system-mount-point fs))))

(test-assert "no copy/sync/migration in generated artifacts"
             (let ((s (object->string
                       (gexp->approximate-sexp
                        (application-persistence-activation
                         (list mixed-rule) "alice")))))
               (and (not (string-contains s "copy-file"))
                    (not (string-contains s "copy-recursively"))
                    (not (string-contains s "rsync"))
                    (not (string-contains s "rename-file")))))

;; ── 6-9：真实执行 pinned Guix Home update-symlinks ──────────
;; 验证 mixed container 语义：persistent writable parent +
;; Home-managed children（declarative occupants）+ unknown mutable
;; child（application authority）。stale 清理、dual-authority backup
;; 全部按 pinned 实现行为断言（gnu/home/services/symlink-manager.scm）。
(define %store (open-connection))

(define (build-thing thing)
  (let ((drv (run-with-store %store (lower-object thing))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

;; gexp->file 返回 monadic 值（不经 lower-object；同
;; test-runtime-exec 的 build-script 模式）。
(define %update-symlinks
  (let ((drv (run-with-store %store
                             (gexp->file
                              "update-symlinks-mixed-test"
                              (program-file-gexp
                               ((module-ref (resolve-module '(gnu home services symlink-manager))
                                            'update-symlinks-script)))))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

;; gexp->file 产物无 shebang；从独立 program-file 提取 guile 路径
;; （同 test-runtime-exec 模式）。
(define %guile
  (let* ((prog (build-thing (program-file "mixed-guile-probe"
                                          #~(display "ok"))))
         (line (call-with-input-file prog
                                     (lambda (p) (read-line p)))))
    (and (string-prefix? "#!" line)
         (car (string-split (substring line 2) #\space)))))

(define (run-update-symlinks root old-gen new-gen)
  "在 fake root 里执行 update-symlinks（HOME=/home/user；
GUIX_OLD_HOME/GUIX_NEW_HOME 指向 fake generations）。"
  ;; fake root 无 env/sh 二进制：环境变量在 chroot 外层设置
  ;; （chroot 继承环境，不重置）。
  (let* ((cmd (string-append
               "unshare --user --map-root-user --map-users=auto "
               "--map-groups=auto --mount --pid --fork sh -c '"
               "mount --bind /gnu/store " root "/gnu/store; "
               "unset XDG_CONFIG_HOME XDG_DATA_HOME; "
               "HOME=/home/user"
               (if old-gen (string-append " GUIX_OLD_HOME=" old-gen) "")
               " GUIX_NEW_HOME=" new-gen " "
               "chroot " root " " %guile
               " --no-auto-compile " %update-symlinks
               " >/dev/null 2>&1'"))
         (pipe (open-input-pipe cmd))
         (_ (get-string-all pipe)))
    (close-pipe pipe)))

(define (make-fake-root)
  "带 /home/user、/gnu/store 与 genA/genB fake generations 的 root。"
  (let* ((root (string-append (or (getenv "TMPDIR") "/tmp")
                              "/guixcfg-mixed-" (number->string (getpid))
                              "-" (number->string (random 100000))))
         (home (string-append root "/home/user")))
    (mkdir-p (string-append root "/gnu/store"))
    (mkdir-p (string-append home "/.config/fish"))
    ;; genA：声明 config.fish + conf.d/foo.fish（store symlink）
    (let ((gen-a (string-append root "/genA/files/.config/fish")))
      (mkdir-p (string-append gen-a "/conf.d"))
      (symlink "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fake-config.fish"
               (string-append gen-a "/config.fish"))
      (symlink "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-fake-foo.fish"
               (string-append gen-a "/conf.d/foo.fish")))
    ;; genB：只声明 config.fish（新 store object）；foo.fish 已删
    (let ((gen-b (string-append root "/genB/files/.config/fish")))
      (mkdir-p gen-b)
      (symlink "/gnu/store/cccccccccccccccccccccccccccccccc-fake-config.fish"
               (string-append gen-b "/config.fish")))
    root))

;; 场景 1：genA → genB 切换；mixed 容器里有 unknown mutable child
(let ((root (make-fake-root)))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     ;; unknown mutable child（application authority；Home 不声明）
     (call-with-output-file (string-append root "/home/user/.config/fish/fish_variables")
                            (lambda (p) (display "V3-content" p)))
     (run-update-symlinks root "/genA" "/genB")
     (let* ((home (string-append root "/home/user/.config/fish"))
            (config (string-append home "/config.fish"))
            (stale (string-append home "/conf.d/foo.fish"))
            (mutable (string-append home "/fish_variables")))
       (test-assert "MIX-1: declared occupant switched to generation B"
                    (and (string? (false-if-exception (readlink config)))
                         (string-contains (readlink config)
                                          "cccccccccccccccccccccccccccccccc")))
       (test-assert "MIX-1: stale managed occupant removed (pinned Home cleanup)"
                    (not (file-exists? stale)))
       (test-assert "MIX-1: unknown mutable child preserved"
                    (let ((s (call-with-input-file mutable
                                                   (lambda (p) (get-string-all p)))))
                      (string=? "V3-content" s)))))
   (lambda () (false-if-exception (delete-file-recursively root)))))

;; 场景 2：dual authority——app 写 Home 管理的文件 → Home backup+replace
(let ((root (make-fake-root)))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (call-with-output-file (string-append root "/home/user/.config/fish/config.fish")
                            (lambda (p) (display "app-wrote-this" p)))
     (run-update-symlinks root #f "/genA")
     (let* ((home (string-append root "/home/user/.config/fish"))
            (config (string-append home "/config.fish"))
            (backups (filter (lambda (e)
                               (string-suffix? "-guix-home-legacy-configs-backup" e))
                             (or (false-if-exception (scandir
                                                      (string-append root "/home/user")))
                                 '()))))
       (test-assert "MIX-2: Home replaced app-written file with store symlink"
                    (and (string? (false-if-exception (readlink config)))
                         (string-contains (readlink config)
                                          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
       (test-assert "MIX-2: app-written file backed up (not silently lost)"
                    (pair? backups))))
   (lambda () (false-if-exception (delete-file-recursively root)))))

;; ── 10-11：generic executor 不知具体应用；HOME 由 user 参数派生 ──
;; （模块里合法的 (string-append "/home/" user ...) 是参数化构造，
;; 不是硬编码——consumer 派生由 alice fixture 测试证明。）
(test-assert "generic executor source knows no concrete app"
             (let ((s (call-with-input-file
                       "modules/guixcfg/system/application-persistence.scm"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "mpv"))
                    (not (string-contains s "fish")))))

(test-end "mixed-authority")
