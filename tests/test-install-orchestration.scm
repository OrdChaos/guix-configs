;;; (guixcfg system install) 编排层测试：纯分类 / 计划输出 / 确认匹配 /
;;; privilege handoff argv / 事务 root gate。
;;;
;;; 全部断言只走纯路径（分类 alist、计划行、argv、非 root 事务的
;;; fail-closed 前置）——绝不触碰真实磁盘 / cryptsetup / mount /
;;; guix system init。

(use-modules (guixcfg system install)
             (guixcfg system deploy)
             (guixcfg security enroll)
             (srfi srfi-64)
             (srfi srfi-1)
             (srfi srfi-13))

(test-runner-current (test-runner-simple))

(define %root "/repo")

;; 非破坏性 override（acons 前插：assq-ref 命中最前条目）。
;; 禁止 assoc-set! 改写共享的引用常量——测试间污染（已实测）。
(define (probes-with base . overrides)
  (fold (lambda (kv acc) (acons (car kv) (cdr kv) acc))
        base overrides))

;;; ────────────────────────────────────────────────────────────
;;; 纯分类：disk

(define (stage-of probes id)
  (let ((s (find (lambda (s) (eq? (install-stage-id s) id))
                 (classify-install-probes probes))))
    (install-stage-status s)))

(define %empty-disk-probes
  '((partition-table . #f) (luks-volume . #f) (luks-open . #f)
    (btrfs-rootfs . #f) (targets-mounted . #f)
    (facts-file . #f) (luks-uuid . #f)
    (sb-keys . none) (keystore . #f)
    (identity . #f) (password-hash . #f)
    (init-markers . #f) (esp-markers . #f)
    (commit . unknown)))

;; 真实 facts 文件（classify-facts 会 load-machine-facts 实际读取——
;; 必须指向存在的文件；内容 UUID 与 %complete-probes 的 luks-uuid 一致）。
(define %facts-file
  (string-append "/tmp/guixcfg-test-install-facts-"
                 (number->string (getpid)) ".scm"))

(call-with-output-file %facts-file
                       (lambda (port)
                         (write '((luks-uuid . "11111111-1111-1111-1111-111111111111"))
                                port)
                         (newline port)))

(define %complete-probes
  `((partition-table . #t) (luks-volume . #t) (luks-open . #t)
    (btrfs-rootfs . #t) (targets-mounted . #t)
    (facts-file . ,%facts-file)
    (luks-uuid . "11111111-1111-1111-1111-111111111111")
    (sb-keys . complete) (keystore . #t)
    (identity . #t) (password-hash . #t)
    (init-markers . #t) (esp-markers . #t)
    (commit . committed)))

(test-begin "install-orchestration")

(test-equal "fresh disk: nothing present"
            'fresh
            (stage-of %empty-disk-probes 'disk))

(test-equal "complete disk: partition table + LUKS + btrfs"
            'complete
            (stage-of %complete-probes 'disk))

(test-equal "ambiguous disk: partitioned + LUKS but btrfs unreadable (LUKS closed)"
            'ambiguous
            (stage-of (probes-with %complete-probes '(luks-open . #f) '(btrfs-rootfs . #f))
                      'disk))

(test-equal "incompatible disk: partition table without LUKS"
            'incompatible
            (stage-of (probes-with %empty-disk-probes '(luks-volume . #f) '(partition-table . #t))
                      'disk))

(test-equal "incompatible disk: LUKS/Btrfs without partition table"
            'incompatible
            (stage-of (probes-with %empty-disk-probes '(luks-volume . #t))
                      'disk))

;; 绝不把探测失败（btrfs 探不到）误判为 fresh 而重格式化：
;; fresh 要求三者同时缺席。
(test-assert "probe failure never classifies as fresh (fail closed against re-wipe)"
             (not (eq? 'fresh
                       (stage-of (probes-with %empty-disk-probes '(luks-volume . #t))
                                 'disk))))

;;; ────────────────────────────────────────────────────────────
;;; 纯分类：其余阶段

(test-equal "mounts complete when targets mounted"
            'complete
            (stage-of %complete-probes 'mounts))

(test-equal "mounts resumable when disk complete but unmounted"
            'resumable
            (stage-of (probes-with %complete-probes '(targets-mounted . #f))
                      'mounts))

(test-equal "facts complete when facts match the device UUID"
            'complete
            (stage-of %complete-probes 'facts))

(test-equal "facts resumable when facts file missing"
            'resumable
            (stage-of %empty-disk-probes 'facts))

(test-equal "facts incompatible when facts UUID mismatches the device"
            'incompatible
            (stage-of (probes-with %complete-probes '(luks-uuid . "22222222-2222-2222-2222-222222222222"))
                      'facts))

(test-equal "sb-keys complete"
            'complete
            (stage-of %complete-probes 'sb-keys))

(test-equal "sb-keys fresh"
            'fresh
            (stage-of %empty-disk-probes 'sb-keys))

(test-equal "sb-keys partial is incompatible (keygen refuses overwrite)"
            'incompatible
            (stage-of (probes-with %complete-probes '(sb-keys . partial))
                      'sb-keys))

(test-equal "secrets resumable (idempotent re-run)"
            'resumable
            (stage-of (probes-with %complete-probes '(identity . #f)) 'secrets))

(test-equal "system-init complete when markers + ESP artifacts present"
            'complete
            (stage-of %complete-probes 'system-init))

(test-equal "system-init resumable when partially present"
            'resumable
            (stage-of (probes-with %complete-probes '(esp-markers . #f))
                      'system-init))

(test-equal "system-init fresh"
            'fresh
            (stage-of %empty-disk-probes 'system-init))

(test-equal "commit complete"
            'complete
            (stage-of %complete-probes 'commit-root))

(test-equal "commit unknown is incompatible (fail closed)"
            'incompatible
            (stage-of %empty-disk-probes 'commit-root))

;; 全部 9 个阶段都在（顺序 = %install-stage-ids）
(test-equal "classification yields all stages in order"
            %install-stage-ids
            (map install-stage-id (classify-install-probes %empty-disk-probes)))

;;; ────────────────────────────────────────────────────────────
;;; 计划输出（§9 格式）

(define %plan-state
  (install-state
   (host "laptop")
   (device "/dev/nvme0n1")
   (device-model "SAMSUNG MZVL21T0")
   (stages (classify-install-probes %empty-disk-probes))))

(define plan-text (string-join (install-plan-lines %plan-state) "\n"))

(test-assert "plan shows host and device"
             (and (string-contains plan-text "Host:   laptop")
                  (string-contains plan-text "Device: /dev/nvme0n1")))

(test-assert "plan shows model"
             (string-contains plan-text "SAMSUNG MZVL21T0"))

(test-assert "plan marks the device as erased"
             (string-contains plan-text "/dev/nvme0n1 will be erased"))

(test-assert "plan excludes TPM and firmware PK enrollment"
             (and (string-contains plan-text "TPM enrollment")
                  (string-contains plan-text
                                  "firmware Secure Boot PK enrollment")))

(test-assert "plan shows all stage ids"
             (every (lambda (id)
                      (string-contains plan-text
                                       (symbol->string id)))
                    %install-stage-ids))

;;; ────────────────────────────────────────────────────────────
;;; 破坏性确认匹配（§8/§42）

(test-assert "confirmation accepts the exact device path"
             (install-confirmed? "/dev/nvme0n1" "/dev/nvme0n1"))

(test-assert "confirmation rejects a different path"
             (not (install-confirmed? "/dev/sda" "/dev/nvme0n1")))

(test-assert "confirmation rejects a bare yes"
             (not (install-confirmed? "y" "/dev/nvme0n1")))

(test-assert "confirmation rejects empty input"
             (not (install-confirmed? "" "/dev/nvme0n1")))

(test-assert "confirmation rejects EOF"
             (not (install-confirmed? (eof-object) "/dev/nvme0n1")))

(test-assert "confirmation rejects non-string input"
             (not (install-confirmed? #f "/dev/nvme0n1")))

(test-assert "confirm UI demands the full device path"
             (let ((text (string-join (install-confirm-lines %plan-state)
                                      "\n")))
               (and (string-contains text "ALL DATA ON /dev/nvme0n1 WILL BE DESTROYED")
                    (string-contains text "Type the full device path to continue:"))))

;;; ────────────────────────────────────────────────────────────
;;; argv（§13/§29/§47）

(define init-argv (system-init-argv %root "laptop"))

(test-assert "system init uses pinned channels.lock.scm"
             (and (member "-C" init-argv)
                  (member "/repo/channels.lock.scm" init-argv)))

(test-assert "system init -L is absolute"
             (equal? "/repo/modules"
                    (and=> (member "-L" init-argv) cadr)))

(test-equal "system init targets the explicit host file and /mnt"
            '("system" "init" "/mnt" "-L" "/repo/modules"
              "modules/guixcfg/hosts/laptop.scm")
            (cdr (member "--" init-argv)))

(define privileged (install-privileged-argv "/bin/blue"
                                            "/repo/blueprint.scm"
                                            "laptop" "/dev/nvme0n1"))

(test-assert "install handoff re-executes the same Blue via sudo"
             (and (equal? (car privileged) "sudo")
                  (member "/bin/blue" privileged)
                  (member "-f" privileged)
                  (member "/repo/blueprint.scm" privileged)))

(test-assert "install handoff uses the privileged Blue store"
             (member "--store-directory=/run/guixcfg/.blue-store"
                     privileged))

(test-assert "install handoff argv separates HOST and DEVICE (no shell string)"
             (let ((tail (cdr (member ".install-root" privileged))))
               (and (equal? tail '("laptop" "/dev/nvme0n1"))
                    (not (any (lambda (x)
                                (or (string-contains x "&&")
                                    (string-contains x ";")
                                    (string-contains x "|")))
                              privileged)))))

(define enroll-privileged (enroll-privileged-argv "/bin/blue"
                                                  "/repo/blueprint.scm"
                                                  "laptop"))

(test-assert "enroll handoff uses the same model (sudo + same Blue + -f + .enroll-root HOST)"
             (let ((tail (cdr (member ".enroll-root" enroll-privileged))))
               (and (equal? (car enroll-privileged) "sudo")
                    (member "/bin/blue" enroll-privileged)
                    (member "/repo/blueprint.scm" enroll-privileged)
                    (member "--store-directory=/run/guixcfg/.blue-store"
                            enroll-privileged)
                    (equal? tail '("laptop")))))

(test-equal "sb-keygen tool argv pins the lockfile and passes the keydir"
            "/mnt/persist/system/keys/secure-boot"
            (last (sb-keygen-tool-argv %root
                                       "/mnt/persist/system/keys/secure-boot")))

(test-assert "sb-keygen tool argv runs inside the keygen manifest shell"
             (let ((argv (sb-keygen-tool-argv %root "/keydir")))
               (and (member "manifests/secure-boot-keygen.scm" argv)
                    (member "tools/secure-boot-keygen.scm" argv))))

(test-assert "sb-keystore tool argv runs inside the enroll manifest shell"
             (let ((argv (sb-keystore-tool-argv %root "/keydir")))
               (and (member "manifests/secure-boot-enroll.scm" argv)
                    (member "tools/secure-boot-enroll.scm" argv))))

(test-equal "commit-root tool argv passes the target"
            '("/mnt")
            (let ((argv (commit-root-tool-argv %root "/mnt")))
              (cdr (member "commit-root" argv))))

(define install-cli (install-cli-argv %root "run" "laptop" "/dev/nvme0n1"))

(test-assert "install CLI runs in the pinned repl (not in-process)"
             (and (member "-C" install-cli)
                  (member "/repo/channels.lock.scm" install-cli)
                  (member "tools/install-cli.scm" install-cli)))

(test-equal "install CLI argv separates mode, HOST and DEVICE"
            '("run" "laptop" "/dev/nvme0n1")
            (cddr (member "tools/install-cli.scm" install-cli)))

(define enroll-cli (enroll-cli-argv %root "plan" "laptop"))

(test-assert "enroll CLI runs in the pinned repl (not in-process)"
             (and (member "tools/enroll-cli.scm" enroll-cli)
                  (member "/repo/channels.lock.scm" enroll-cli)))

(test-equal "enroll CLI argv separates mode and HOST"
            '("plan" "laptop")
            (cddr (member "tools/enroll-cli.scm" enroll-cli)))

;;; ────────────────────────────────────────────────────────────
;;; 事务 root gate（非 root 立即 1，绝不触碰 exec / confirm）

(define (exploding-exec . argv)
  (error "exec must not be called before the root gate"))

(define (exploding-confirm state)
  (error "confirm must not be called before the root gate"))

(test-equal "install transaction refuses non-root with exit 1 (no exec)"
            1
            (install-transaction! "/repo" "laptop" "/dev/nvme0n1"
                                  #:exec exploding-exec
                                  #:on-confirm exploding-confirm))

(test-equal "enroll transaction refuses non-root with exit 1 (no exec)"
            1
            (enroll-transaction! "/repo" "laptop"
                                 #:exec exploding-exec
                                 #:on-firmware-confirm exploding-confirm))

;;; ────────────────────────────────────────────────────────────
;;; preflight checks 形态（只读，可安全求值——本机不是安装环境，
;;; 检查应 fail closed 而非抛错）

(test-assert "install preflight checks are ((label . thunk)) with (status . detail) results"
             (let ((checks (install-preflight-checks "/repo" "laptop"
                                                     "/dev/nvme0n1")))
               (every (lambda (check)
                        (and (pair? check)
                             (string? (car check))
                             (procedure? (cdr check))
                             (let ((r ((cdr check))))
                               (and (pair? r)
                                    (memq (car r) '(ok fail))))))
                      checks)))

(test-assert "install preflight fails closed on an unknown host"
             (let ((checks (install-preflight-checks "/repo" "nosuchhost"
                                                     "/dev/nvme0n1")))
               (eq? 'fail
                    (car ((cdr (find (lambda (c)
                                       (string=? (car c) "host known"))
                                     checks)))))))

(test-end "install-orchestration")

(false-if-exception (delete-file %facts-file))
