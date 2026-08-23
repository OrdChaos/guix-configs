;;; commit-root 挂载语义的集成测试（scratch Btrfs loopback，真实 mount/
;;; rename/snapshot，不 mock 命令）。
;;;
;;; 需要 root + loop 设备（宿主通常非 root：run-tests 下自动 skip；
;;; 以 root 单独跑时完整执行——测试 VM/安装环境的真实路径）。
;;;
;;; 覆盖：
;;;   1. rename 保持 mounted view（TARGET content visible after commit）
;;;   2. template readonly（ro=true）
;;;   3. @root-0 内容 == 安装期 root 内容（rename 而非复制）
;;;   4. @root-installing 最终不存在
;;;   5. @root-0 exists
;;;   6. TARGET 在 commit 后仍有 etc/gnu/persist/boot
;;;   7. @persist-var-guix data intact（收养）
;;;   8. state current-generation = 0（first-boot）
;;;   9. deploy program 在 commit 后仍可执行（marker 实证）
;;;  10. rerun safe（第二次 commit-root 是 no-op）

(use-modules (guixcfg storage commit)
             (guixcfg storage model)
             (guixcfg storage root-generation)
             (guix build utils)
             (ice-9 popen)     ; open-pipe*
             (rnrs io ports)   ; get-string-all
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define scratch "/tmp/guixcfg-commit-scratch.btrfs")
(define top "/mnt/top-guixcfg-test")
(define target "/mnt/target-guixcfg-test")

(define (sh . args)
  (unless (zero? (apply system* args))
    (error "command failed" args)))

(define (run-out . args)
  (let ((port (apply open-pipe* OPEN_READ args)))
    (let ((s (get-string-all port)))
      (close-pipe port)
      s)))

(test-begin "commit-root")

(if (not (zero? (getuid)))
  (begin
   (test-skip 19)
   (format #t "commit-root test skipped: needs root (scratch loopback Btrfs)~%"))
  (let* ((loop (string-trim-right (run-out "losetup" "-f") #\newline))
         (cleanup (lambda ()
                    (false-if-exception (sh "umount" "-R" target))
                    (false-if-exception (sh "umount" "-R" top))
                    (false-if-exception (sh "losetup" "-d" loop))
                    (false-if-exception (delete-file "/dev/mapper/guixcfg-test-luks"))
                    (false-if-exception (delete-file scratch))
                    (false-if-exception (delete-file "/tmp/commit-deploy-marker")))))
    (dynamic-wind
     (lambda () #t)
     (lambda ()
       ;; ── 环境：scratch Btrfs + 模拟 cryptroot mapper ──────
       (sh "truncate" "-s" "512M" scratch)
       (sh "mkfs.btrfs" "-f" scratch)
       (sh "losetup" loop scratch)
       (setenv "GUIXCFG_TEST_LUKS_MAPPER" "/dev/mapper/guixcfg-test-luks")
       (sh "ln" "-sf" loop "/dev/mapper/guixcfg-test-luks")
       (mkdir-p top)
       (mkdir-p target)
       ;; 顶层挂载 + 子卷构造（subvolid=5）
       (sh "mount" "-o" "subvolid=5" loop top)
       (sh "btrfs" "subvolume" "create" (string-append top "/@root-installing"))
       (sh "btrfs" "subvolume" "create" (string-append top "/@persist-var-guix"))
       (sh "btrfs" "subvolume" "create" (string-append top "/@persist-system"))
       ;; 安装期 root 内容（init 后的样子）
       (let ((root (string-append top "/@root-installing")))
         (for-each (lambda (d) (mkdir-p (string-append root "/" d)))
                   '("etc" "gnu" "persist" "boot"))
         (call-with-output-file (string-append root "/file")
                                (lambda (p) (display "sentinel-commit" p)))
         (call-with-output-file (string-append root "/etc/issue")
                                (lambda (p) (display "test-issue" p)))
         (mkdir-p (string-append root "/var/guix/db"))
         (call-with-output-file (string-append root "/var/guix/db/registry")
                                (lambda (p) (display "guix-db" p)))
         (let ((deploy (string-append root "/boot/deploy-uki")))
           (call-with-output-file deploy
                                  (lambda (p)
                                    (display "#!/bin/sh\necho deployed > /tmp/commit-deploy-marker\n" p)))
           (chmod deploy #o755)))
       ;; TARGET 挂 @root-installing（安装期视图）
       (sh "mount" "-o" "subvol=@root-installing" loop target)
       ;; ── commit（真实调用）──────────────────────────────
       (commit-root-generation target)
       ;; 1. mounted view 保持
       (test-equal "TARGET content visible after commit"
                   "sentinel-commit"
                   (call-with-input-file (string-append target "/file")
                                         get-string-all))
       (test-assert "TARGET/etc exists"
                    (file-exists? (string-append target "/etc/issue")))
       ;; 6. TARGET 关键目录
       (for-each
        (lambda (d)
          (test-assert (string-append "TARGET/" d " exists")
                       (file-exists? (string-append target "/" d))))
        '("etc" "gnu" "persist" "boot"))
       ;; 5. @root-0 exists
       (test-assert "@root-0 exists"
                    (file-exists? (string-append top "/@root-0")))
       ;; 4. @root-installing absent
       (test-assert "@root-installing absent"
                    (not (file-exists? (string-append top "/@root-installing"))))
       ;; 3. 内容 == 安装期 root（rename 非复制）
       (test-equal "@root-0 content == install-time content"
                   "sentinel-commit"
                   (call-with-input-file (string-append top "/@root-0/file")
                                         get-string-all))
       ;; 2. template readonly
       (test-assert "template readonly (ro=true)"
                    (string-contains
                     (run-out "btrfs" "property" "get"
                              (string-append top "/@root-template") "ro")
                     "ro=true"))
       ;; 7. @persist-var-guix 收养完整
       (test-equal "@persist-var-guix data intact"
                   "guix-db"
                   (call-with-input-file
                    (string-append top "/@persist-var-guix/db/registry")
                    get-string-all))
       ;; 8. state current-generation = 0（first-boot）
       (let* ((state-path (state-file-path
                           (string-append top "/@persist-system")))
              (state (call-with-input-file state-path read)))
         (test-equal "state current-generation = 0"
                     0 (assq-ref state 'current-generation)))
       ;; 9. deploy 实际执行（marker）
       (test-equal "deploy-uki executed"
                   "deployed\n"
                   (call-with-input-file "/tmp/commit-deploy-marker"
                                         get-string-all))
       ;; 10. rerun safe（no-op：返回 committed，不破坏任何状态）
       (test-eq "rerun is a no-op (returns committed)"
                'committed (commit-root-generation target))
       (test-assert "@root-0 still present after rerun"
                    (file-exists? (string-append top "/@root-0")))
       (test-assert "template still readonly after rerun"
                    (string-contains
                     (run-out "btrfs" "property" "get"
                              (string-append top "/@root-template") "ro")
                     "ro=true")))
     cleanup)))

;;; ────────────────────────────────────────────────────────────
;;; rename 后 deploy 失败 → 回滚到 @root-installing。
;;; 新 scratch 环境：deploy 脚本 exit 1 触发失败路径。

(let ((scratch2 "/tmp/guixcfg-commit-fail.btrfs")
      (top2 "/mnt/top-guixcfg-fail")
      (target2 "/mnt/target-guixcfg-fail"))
  (if (not (zero? (getuid)))
    (test-skip 3)
    (let* ((loop (string-trim-right (run-out "losetup" "-f") #\newline))
           (cleanup (lambda ()
                      (false-if-exception (sh "umount" "-R" target2))
                      (false-if-exception (sh "umount" "-R" top2))
                      (false-if-exception (sh "losetup" "-d" loop))
                      (false-if-exception (delete-file "/dev/mapper/guixcfg-test-luks"))
                      (false-if-exception (delete-file scratch2)))))
      (dynamic-wind
       (lambda () #t)
       (lambda ()
         (sh "truncate" "-s" "512M" scratch2)
         (sh "mkfs.btrfs" "-f" scratch2)
         (sh "losetup" loop scratch2)
         (sh "ln" "-sf" loop "/dev/mapper/guixcfg-test-luks")
         (mkdir-p top2)
         (mkdir-p target2)
         (sh "mount" "-o" "subvolid=5" loop top2)
         (sh "btrfs" "subvolume" "create" (string-append top2 "/@root-installing"))
         (sh "btrfs" "subvolume" "create" (string-append top2 "/@persist-var-guix"))
         (sh "btrfs" "subvolume" "create" (string-append top2 "/@persist-system"))
         (let ((root (string-append top2 "/@root-installing")))
           (for-each (lambda (d) (mkdir-p (string-append root "/" d)))
                     '("etc" "gnu" "persist" "boot"))
           (mkdir-p (string-append root "/var/guix/db"))
           (let ((deploy (string-append root "/boot/deploy-uki")))
             (call-with-output-file deploy
                                    (lambda (p) (display "#!/bin/sh\nexit 1\n" p)))
             (chmod deploy #o755)))
         (sh "mount" "-o" "subvol=@root-installing" loop target2)
         ;; deploy 失败 → commit 抛错 → 回滚
         (let ((status (false-if-exception
                        (system* "guile" "--no-auto-compile"
                                 "-L" "/mnt/cfg/modules"
                                 "-c"
                                 (string-append
                                  "(use-modules (guixcfg storage commit)) "
                                  "(commit-root-generation \"" target2 "\")")))))
           (test-assert "commit exits non-zero when deploy fails"
                        (and status (not (zero? status)))))
         ;; 回滚后：@root-installing 恢复、@root-0 不存在、template 删除
         (test-assert "@root-installing restored after rollback"
                      (file-exists? (string-append top2 "/@root-installing")))
         (test-assert "@root-0 absent after rollback"
                      (not (file-exists? (string-append top2 "/@root-0")))))
       cleanup))))

(test-end "commit-root")
