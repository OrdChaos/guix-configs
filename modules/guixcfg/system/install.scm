;;; blue install 的安装编排层（docs/operations/installation.md 的
;;; Blue 主路径）。
;;;
;;; 职责边界（与 (guixcfg system deploy) 的纯 argv 层互补）：
;;;   - install preflight / 阶段状态检测（纯分类 + 只读探针）/
;;;     resume 判定 / 事务编排 / 安装后验证；
;;;   - Blue（blueprint.scm）只做 argv 校验、dry-run 分发、privilege
;;;     handoff、破坏性确认 UI 与退出码传播；
;;;   - 磁盘 mutation 机制唯一 authority 仍是 (guixcfg storage
;;;     install)（run-install 的执行单元拆分复用：preflight-environment!
;;;     / execute-plan / execute-mounts! / write-machine-facts）；
;;;     facts / secrets / Secure Boot keygen+keystore / system init /
;;;     commit-root 各自复用现有 domain mechanism，本模块绝不复制；
;;;   - 不新增 install-state 数据库：resume 全部从可观察事实推断
;;;     （分区表 / LUKS header / btrfs / facts 文件 / /mnt 布局 /
;;;     ESP artifacts / commit state）；
;;;   - 可恢复语义：complete → skip；fresh → execute；resumable →
;;;     幂等重跑；incompatible/ambiguous → fail closed 报告
;;;     expected/actual/stage，绝不自动重新格式化。
;;;
;;; 阶段顺序以真实依赖为准（与 disk-install + installation.md 一致）：
;;;   disk → mounts → facts → sb-keys → secrets → sb-keystore
;;;   → system-init → commit-root → repo → validate。
;;;   关键依赖：sb-keys 在 system-init 前（部署期 UKI 签名需要
;;;   db.key/db.crt）；secrets 在 system-init 前（AGENT.md §5：阶段 5
;;;   必须先于 system init）；identity 解锁在 disk 前（让 LUKS
;;;   passphrase 走 luks-recovery.age 而非交互）；repo 在 commit-root
;;;   后（/mnt/persist/data-home 挂载且系统已可启动，runbook 阶段 10
;;;   的相对顺序）。
;;;
;;; 退出码契约（docs/operations/installation.md）：
;;;   0 = 成功 / 已合规（skip/resume 收敛到完整状态）
;;;   1 = 前置/配置失败，未发生任何 mutation
;;;   2 = 已发生部分 mutation，无法安全自动继续（报告阶段与恢复方式）
;;;   3 = 用户显式中止（破坏性确认未通过）
;;;
;;; 本模块不执行任何子进程；所有 subprocess 经调用方注入的 EXEC
;;; （(lambda (argv) -> exit-status)，cwd = 仓库根）。dry-run 由调用方
;;; 保证（绝不调用 install-transaction!）。

(define-module (guixcfg system install)
               #:use-module (guixcfg storage model)      ; persist-mount-point、%luks-mapper-path、%system-partlabel、by-partlabel-path、%btrfs-filesystem-label
               #:use-module (guixcfg storage policies)   ; storage-policy-by-name
               #:use-module (guixcfg storage validate)   ; validate-policy / validate-target / check-failure-message
               #:use-module (guixcfg storage device)     ; probe-device / first-command-line
               #:use-module (guixcfg storage plan)       ; storage-plan / display-plan
               #:use-module (guixcfg storage install)    ; %required-commands、preflight-environment!、execute-plan、execute-mounts!、write-machine-facts、warn-if-store-in-ram、read-secret-line
               #:use-module (guixcfg storage filesystem) ; execute-luks-open
               #:use-module (guixcfg storage subvolume)  ; %btrfs-top-mount（top mount 探针）
               #:use-module (guixcfg storage commit)     ; commit-state
               #:use-module (guixcfg security age)       ; runtime-identity-present?、age-unlock!、ensure-installed-identity!、%installed-identity-path、%account-credentials-dir、provision-password-hash!
               #:use-module (guixcfg security credential-source) ; resolve-luks-passphrase-source
               #:use-module (guixcfg system machine-facts) ; load-machine-facts（facts 内容校验）
               #:use-module (guixcfg system deploy)      ; system-init-argv / sb-keygen-tool-argv / sb-keystore-tool-argv / commit-root-tool-argv / channels-structure-ok?
               #:use-module (guixcfg boot layout)        ; %esp-mount-point
               #:use-module (guixcfg users facts)        ; %primary-user（账户事实唯一来源）
               #:use-module (guix records)
               #:use-module (ice-9 match)
               #:use-module (ice-9 popen)               ; open-pipe* / close-pipe（cryptsetup isLuks 退出码探针）
               #:use-module (ice-9 rdelim)
               #:use-module (ice-9 format)
               #:use-module (srfi srfi-1)
               #:export (<install-stage>
                         install-stage make-install-stage install-stage?
                         install-stage-id install-stage-status install-stage-detail
                         <install-state>
                         install-state make-install-state install-state?
                         install-state-host install-state-device
                         install-state-device-facts install-state-device-model
                         install-state-stages
                         ;; 纯分类（可测试）
                         %install-stage-ids
                         classify-install-probes
                         stage-status
                         ;; 只读探针与检测
                         collect-install-probes
                         detect-install-state
                         ;; preflight checks（blueprint 的 %run-checks 形态）
                         install-preflight-checks
                         ;; 计划输出与确认匹配（纯）
                         install-plan-lines
                         install-confirm-lines
                         install-confirmed?
                         ;; 事务（root 阶段执行；dry-run 绝不调用）
                         install-transaction!
                         ;; repo 复制机制（事务 repo 阶段；导出供测试）
                         %repo-copy-markers
                         install-repo-path
                         repo-copy-present?
                         install-repository!
                         ;; SB keydir 完整性（validate 共用；导出供测试）
                         %sb-key-file-names
                         %keystore-auth-paths
                         sb-key-material-complete?
                         ;; 安装后验证（只读）
                         validate-installation
                         install-next-step-lines))

;;; ────────────────────────────────────────────────────────────
;;; 固定事实

;; 仓库内相对路径（installation.md 阶段 7 的 install secret）。
(define %user-password-hash-rel "modules/guixcfg/users/secrets/user-password.hash.age")

;; 安装目标的 SB keydir（target-prefix 语义与 boot/uki.scm 的部署期
;; 解析一致：mount-point + /persist/system/keys/secure-boot）。
(define (install-keydir target)
  (string-append target
                 (persist-mount-point "@persist-system")
                 "/keys/secure-boot"))

(define (install-facts-path target)
  (string-append target
                 (persist-mount-point "@persist-system")
                 "/facts/host.scm"))

(define (install-identity-path target)
  (string-append target (%installed-identity-path)))

(define (install-password-hash-path target user)
  (string-append target
                 (persist-mount-point "@persist-system")
                 "/accounts/" user "/password.hash"))

(define %sb-key-file-names '("PK.key" "PK.crt" "KEK.key" "KEK.crt"
                             "db.key" "db.crt"))

(define %keystore-auth-paths '("keystore/PK/PK.auth"
                               "keystore/KEK/KEK.auth"
                               "keystore/db/db.auth"))

;; commit-root 会把 /var/guix 收养进 @persist-var-guix（mount-at-install?
;; #f 的刻意设计）——system-1-link 在 commit 后不再位于 /mnt/var/guix；
;; /run/current-system 则是 boot 期产物（init 不创建）。init 完成标记
;; 用 /etc + /boot/deploy-uki（system derivation 的 boot 输出，rename
;; 到 @root-0 后仍可见，VM 实测）。
(define %init-markers '("/etc" "/boot/deploy-uki"))

(define %esp-markers '("/limine.conf" "/EFI/Guix/A/CURRENT.EFI"
                       "/EFI/Guix/A/RECOVERY.EFI"))

;; 仓库 checkout 复制（installation.md 手动 runbook 阶段 10 的机制化）：
;; 目标 = @persist-data-home/<user>/guix-configs（与
;; (guixcfg system user-persistence) 的 guix-configs bind backing
;; 一致——首次 boot 即 bind 到 ~/guix-configs）。检测与验证共用同一
;; 标记集合；.git 必须保留（已装系统上用户 git pull 的入口）。
(define %repo-copy-markers
  '("channels.lock.scm" "modules" "tools" "docs" "manifests" ".git"))

(define (install-repo-path target)
  "TARGET（/mnt）下仓库 checkout 的目标路径。"
  (string-append target
                 (persist-mount-point "@persist-data-home")
                 "/" (user-profile-name %primary-user)
                 "/guix-configs"))

(define (repo-copy-present? target)
  "复制标记是否全部在位（resume 检测 + validate 共用）。"
  (every (lambda (m)
           (file-exists? (string-append (install-repo-path target) "/" m)))
         %repo-copy-markers))

(define (sb-key-material-complete? target)
  "TARGET 下 SB keydir 的 6 密钥 + keystore 3 .auth 是否完整。validate
共用：install 以不完整的 SB 材料收尾会静默产出无法 enroll 的系统
（密钥被外部删除时 sb-keys/sb-keystore 阶段已 skip，validate 必须
fail loud——2026-09 VM 实测：4 个密钥文件在安装窗口内消失，旧
validate 不检查 keydir，直到 first boot 的 enroll 才暴露）。"
  (let ((keydir (install-keydir target)))
    (and (every (lambda (f)
                  (file-exists? (string-append keydir "/" f)))
                %sb-key-file-names)
         (every (lambda (f)
                  (file-exists? (string-append keydir "/" f)))
                %keystore-auth-paths))))

;;; ────────────────────────────────────────────────────────────
;;; 阶段记录与状态符号

;; 阶段状态：'fresh（未开始）/ 'complete（已完成且兼容）/
;; 'resumable（部分但可安全重跑该阶段）/ 'incompatible（部分且
;; 不能安全续跑——fail closed）/ 'ambiguous（需进一步动作才能判定，
;; 如 LUKS 未打开时的 btrfs 状态）。
(define-record-type* <install-stage>
                     install-stage make-install-stage
                     install-stage?
                     (id     install-stage-id)      ; symbol
                     (status install-stage-status)  ; 上述符号
                     (detail install-stage-detail
                             (default #f)))          ; 人类可读说明

(define-record-type* <install-state>
                     install-state make-install-state
                     install-state?
                     (host         install-state-host)
                     (device       install-state-device)
                     (device-facts install-state-device-facts
                                   (default #f))
                     (device-model install-state-device-model
                                   (default #f))
                     (stages       install-state-stages
                                   (default '())))

;; 阶段 id 顺序 = 展示/执行顺序（真实依赖顺序，见模块头）。
(define %install-stage-ids
  '(disk mounts facts sb-keys secrets sb-keystore system-init
          commit-root repo validate))

(define (stage-status state id)
  "STATE 中 id 阶段的 <install-stage>（缺省 #f）。"
  (find (lambda (s) (eq? (install-stage-id s) id))
        (install-state-stages state)))

;;; ────────────────────────────────────────────────────────────
;;; 纯分类：探针 alist → 阶段状态列表。
;;; 探针 key（collect-install-probes 收集）：
;;;   partition-table  #t/#f —— /dev/disk/by-partlabel/{esp,system} 存在
;;;   luks-volume      #t/#f —— cryptsetup isLuks by-partlabel system
;;;   luks-open        #t/#f —— /dev/mapper/cryptroot 存在
;;;   btrfs-rootfs     #t/#f —— btrfs filesystem show mapper 含 rootfs
;;;   targets-mounted  #t/#f —— /mnt 与 /mnt/efi 均已挂载
;;;   top-mounted      #t/#f —— btrfs 顶层已挂载（commit 探针依赖）
;;;   facts-file       path/#f
;;;   luks-uuid        uuid 字符串/#f（cryptsetup luksUUID）
;;;   sb-keys          'none | 'partial | 'complete
;;;   keystore         #t/#f
;;;   identity         #t/#f（target 下 installed identity）
;;;   password-hash    #t/#f
;;;   init-markers     #t/#f
;;;   esp-markers      #t/#f
;;;   commit           'unknown | 'fresh | 'committed

(define (classify-disk p)
  (let ((pt (assq-ref p 'partition-table))
        (luks (assq-ref p 'luks-volume))
        (btrfs (assq-ref p 'btrfs-rootfs)))
    (cond
      ((and (not pt) (not luks) (not btrfs))
       '(fresh . "empty target: partition table, LUKS and Btrfs all absent"))
      ((and pt luks btrfs)
       '(complete . "partition table + LUKS2 + Btrfs rootfs present"))
      ((and pt luks (not btrfs))
       ;; 两种可能：btrfs 尚未格式化（partial）或 LUKS 未打开导致
       ;; 探测不到（可恢复）。事务期打开 LUKS 后二次探测定论；
       ;; 展示/干燥运行报 ambiguous。
       '(ambiguous . "partitioned + LUKS present; Btrfs state unknown until the volume is opened"))
      ((not pt)
       (cons 'incompatible
             "LUKS/Btrfs present but no partition table was detected; refusing to re-wipe"))
      (else
       (cons 'incompatible
             "partition table present but LUKS volume missing; refusing to re-wipe")))))

(define (classify-mounts p disk-status)
  (cond
    ((and (assq-ref p 'targets-mounted)
          (assq-ref p 'top-mounted))
     '(complete . "/mnt, /mnt/efi and the btrfs top are mounted"))
    ((eq? disk-status 'fresh)
     '(fresh . "nothing to mount yet"))
    ((eq? disk-status 'complete)
     '(resumable . "disk is formatted but not mounted; mounts can be replayed"))
    ((eq? disk-status 'ambiguous)
     '(ambiguous . "depends on disk state (open LUKS to resolve)"))
    (else
     '(incompatible . "disk is not in a mountable state"))))

(define (classify-facts p)
  (let ((file (assq-ref p 'facts-file))
        (uuid (assq-ref p 'luks-uuid)))
    (cond
      ((and file uuid)
       (let ((facts (false-if-exception (load-machine-facts file))))
         (cond
           ((not facts)
            (cons 'incompatible
                  (format #f "facts file ~a is unreadable/invalid" file)))
           ((string=? (or (assq-ref facts 'luks-uuid) "")
                      uuid)
            '(complete . "facts match the on-disk LUKS UUID"))
           (else
            (cons 'incompatible
                  (format #f "facts file ~a declares a LUKS UUID different from the device (~a)"
                          file uuid))))))
      (file
       (cons 'incompatible
             (format #f "facts file ~a exists but the device LUKS UUID cannot be read" file)))
      (else
       '(resumable . "facts file missing; it will be re-materialized from the device")))))

(define (classify-sb-keys p)
  (case (assq-ref p 'sb-keys)
    ((complete) '(complete . "all 6 PK/KEK/db key+crt files present"))
    ((partial)
     (cons 'incompatible
           "Secure Boot key material is partial; keygen refuses to overwrite — delete the key directory manually to regenerate"))
    (else '(fresh . "no Secure Boot key material yet"))))

(define (classify-secrets p)
  (if (and (assq-ref p 'identity) (assq-ref p 'password-hash))
    '(complete . "stable identity and password hash are installed")
    '(resumable . "identity/password provisioning is idempotent; it will be re-run")))

(define (classify-keystore p)
  (if (assq-ref p 'keystore)
    '(complete . "keystore PK/KEK/db .auth files present")
    '(resumable . "keystore build is idempotent; it will be re-run")))

(define (classify-init p)
  (let ((etc (assq-ref p 'init-markers))
        (esp (assq-ref p 'esp-markers)))
    (cond
      ((and etc esp)
       '(complete . "system generation and ESP boot artifacts are installed"))
      ((or etc esp)
       (cons 'resumable
             "init is partially present; re-running guix system init is safe (target /var/guix is re-registered and boot slots are redeployed)"))
      (else
       '(fresh . "guix system init has not run yet")))))

(define (classify-commit p)
  (case (assq-ref p 'commit)
    ((committed) '(complete . "root template + @root-0 + state are committed"))
    ((fresh) '(fresh . "root generation not committed yet"))
    (else
     ;; 探针拿不到状态（如计划期目标盘尚未挂载）时，按挂载状态区分：
     ;; 未挂载 = 尚未到提交阶段（fresh）；已挂载却读不到 = 异常（blocked）。
     (if (assq-ref p 'targets-mounted)
       (cons 'incompatible
             "commit state unknown: neither @root-installing/@root-0 nor state could be determined; inspect the Btrfs top level manually")
       '(fresh . "not applicable yet (target not mounted); will be committed after system init")))))

(define (classify-repo p)
  (if (assq-ref p 'repo-copied)
    '(complete . "repository checkout present under @persist-data-home")
    '(resumable . "repo copy is idempotent; it will be re-run")))

(define (classify-install-probes probes)
  "把 PROBES（collect-install-probes 的 alist）分类为 <install-stage>
  列表（%install-stage-ids 顺序）。纯函数，无 IO。"
  (let* ((disk-status (car (classify-disk probes)))
         (mounts (classify-mounts probes disk-status))
         (facts (classify-facts probes))
         (sb-keys (classify-sb-keys probes))
         (secrets (classify-secrets probes))
         (keystore (classify-keystore probes))
         (init (classify-init probes))
         (commit (classify-commit probes))
         (repo (classify-repo probes)))
    (list
     (install-stage (id 'disk) (status disk-status)
                    (detail (cdr (classify-disk probes))))
     (install-stage (id 'mounts) (status (car mounts))
                    (detail (cdr mounts)))
     (install-stage (id 'facts) (status (car facts))
                    (detail (cdr facts)))
     (install-stage (id 'sb-keys) (status (car sb-keys))
                    (detail (cdr sb-keys)))
     (install-stage (id 'secrets) (status (car secrets))
                    (detail (cdr secrets)))
     (install-stage (id 'sb-keystore) (status (car keystore))
                    (detail (cdr keystore)))
     (install-stage (id 'system-init) (status (car init))
                    (detail (cdr init)))
     (install-stage (id 'commit-root) (status (car commit))
                    (detail (cdr commit)))
     (install-stage (id 'repo) (status (car repo))
                    (detail (cdr repo)))
     (install-stage (id 'validate) (status 'fresh)
                    (detail "always re-run at the end")))))

;;; ────────────────────────────────────────────────────────────
;;; 只读探针（真实 IO；全部 false-if-exception 保护，失败即 #f——
;;; 分类层对此 fail closed，绝不把探测失败误判为 fresh 而重格式化）。

(define (collect-install-probes target device)
  "收集 TARGET（通常 /mnt）与 DEVICE 的可观察安装事实 → alist。
不打开任何东西、不挂载、不写。"
  (let* ((esp-partlabel (by-partlabel-path "esp"))
         (sys-partlabel (by-partlabel-path "system"))
         (mapper %luks-mapper-path)
         (keydir (install-keydir target))
         (user (user-profile-name %primary-user)))
    `((partition-table .
       ,(or (file-exists? esp-partlabel)
            (file-exists? sys-partlabel)))
      (luks-volume .
       ;; cryptsetup isLuks 用退出码表态（0 = 是 LUKS），stdout 无输出
       ;; ——绝不能用输出文本判断（resume 时误判 incompatible，实测）。
       ,(and (file-exists? sys-partlabel)
             (let ((p (false-if-exception
                       (open-pipe* OPEN_READ "cryptsetup" "isLuks"
                                   sys-partlabel))))
               (and p (zero? (status:exit-val (close-pipe p)))))))
      (luks-open . ,(file-exists? mapper))
      (btrfs-rootfs .
       ,(and (file-exists? mapper)
             (let ((v (false-if-exception
                       (first-command-line "btrfs" "filesystem" "show"
                                           mapper))))
               (and v (string-contains v %btrfs-filesystem-label)))))
      (targets-mounted .
       ,(and (let ((src (false-if-exception
                         (first-command-line "findmnt" "-no" "SOURCE"
                                             target))))
               (and src (not (string-null? src))))
             (let ((src (false-if-exception
                         (first-command-line "findmnt" "-no" "SOURCE"
                                             (string-append target
                                                            %esp-mount-point)))))
               (and src (not (string-null? src))))))
      (top-mounted .
       ,(let ((r (false-if-exception
                  (first-command-line "findmnt" "-no" "TARGET"
                                      %btrfs-top-mount))))
          (and r (not (string-null? r)))))
      (facts-file .
       ,(and (file-exists? (install-facts-path target))
             (install-facts-path target)))
      (luks-uuid .
       ,(and (file-exists? sys-partlabel)
             (false-if-exception
              (first-command-line "cryptsetup" "luksUUID"
                                  sys-partlabel))))
      (sb-keys .
       ,(let ((n (count
                  (lambda (f)
                    (file-exists? (string-append keydir "/" f)))
                  %sb-key-file-names)))
          (cond ((= n 6) 'complete)
                ((zero? n) 'none)
                (else 'partial))))
      (keystore .
       ,(every (lambda (f)
                 (file-exists? (string-append keydir "/" f)))
               %keystore-auth-paths))
      (identity . ,(file-exists? (install-identity-path target)))
      (password-hash . ,(file-exists?
                         (install-password-hash-path target user)))
      (init-markers .
       ,(every (lambda (f)
                 (file-exists? (string-append target f)))
               %init-markers))
      (esp-markers .
       ,(every (lambda (f)
                 (file-exists?
                  (string-append target %esp-mount-point f)))
               %esp-markers))
      (commit .
       ,(let ((c (false-if-exception (commit-state))))
          (case c
            ((committed) 'committed)
            ((interrupted-after-rename not-committed) 'fresh)
            (else 'unknown))))
      (repo-copied . ,(repo-copy-present? target)))))

(define* (detect-install-state root host device)
         "探测 DEVICE 并分类安装阶段（只读）。返回 <install-state>。"
         (let* ((facts (false-if-exception (probe-device device)))
                (model (false-if-exception
                        (first-command-line "lsblk" "-dno" "MODEL"
                                            device)))
                (probes (collect-install-probes "/mnt" device))
                (stages (classify-install-probes probes)))
           (install-state
            (host host)
            (device device)
            (device-facts facts)
            (device-model (and model (not (string-null? model)) model))
            (stages stages))))

;;; ────────────────────────────────────────────────────────────
;;; preflight checks（installer environment readiness；与 deployment
;;; doctor 语义不同——这里不要求 facts / git clean）

(define (install-preflight-checks root host device)
  "((label . thunk) ...)：thunk 返回 (ok . detail) 或 (fail . detail)。
只读；user 态与 dry-run 共用。"
  (let ((policy (false-if-exception (storage-policy-by-name host))))
    (list
     (cons "repository root"
           (lambda ()
             (if (and (absolute-file-name? root)
                      (file-exists? (string-append root "/channels.lock.scm"))
                      (file-exists? (string-append root "/modules")))
               '(ok . #f)
               (cons 'fail (string-append "bad repository root: " root)))))
     (cons "channels structure compatible"
           (lambda ()
             (if (false-if-exception (channels-structure-ok? root))
               '(ok . #f)
               '(fail . "channels.scm and channels.lock.scm disagree structurally"))))
     (cons "host known"
           (lambda ()
             (if policy
               (cons 'ok host)
               (cons 'fail
                     (string-append "unknown host or missing storage policy: "
                                    host)))))
     (cons "host policy valid"
           (lambda ()
             (if policy
               (let ((failures (validate-policy policy)))
                 (if (null? failures)
                   '(ok . #f)
                   (cons 'fail
                         (string-join (map check-failure-message failures)
                                      "; "))))
               (cons 'fail "no policy to validate"))))
     (cons "device exists"
           (lambda ()
             (let ((facts (false-if-exception (probe-device device))))
               (cond
                 ((not facts)
                  (cons 'fail
                        (string-append "cannot probe " device
                                       " (lsblk missing or device absent)")))
                 ((device-facts-partition? facts)
                  (cons 'fail
                        (string-append device " is a partition; the whole block device is required")))
                 ((device-facts-mounted? facts)
                  ;; resume：目标分区已存在且挂着（mounts 阶段已
                  ;; 执行）是预期状态；空盘却挂载着才是异常。
                  (if (file-exists? (by-partlabel-path "system"))
                    '(ok . "already mounted (resume state)")
                    (cons 'fail
                          (string-append device " is currently mounted; refusing to touch it"))))
                 ((zero? (device-facts-size facts))
                  (cons 'fail "device reports zero size"))
                 (else
                  (cons 'ok
                        (format #f "~,2f GiB"
                                (/ (device-facts-size facts)
                                   1024.0 1024.0 1024.0))))))))
     (cons "required tools"
           (lambda ()
             (let ((missing
                    (filter (negate
                             (lambda (cmd)
                               (search-path
                                (string-split (or (getenv "PATH") "") #\:)
                                cmd)))
                            (append %required-commands '("guix")))))
               (if (null? missing)
                 '(ok . #f)
                 (cons 'fail
                       (string-append "missing in PATH: "
                                      (string-join missing ", ")
                                      " (check the installer manifest)"))))))
     (cons "UEFI environment"
           (lambda ()
             (if (file-exists? "/sys/firmware/efi")
               '(ok . #f)
               '(fail . "no /sys/firmware/efi; a UEFI booted installer environment is required"))))
     (cons "LUKS mapper free"
           (lambda ()
             (if (file-exists? %luks-mapper-path)
               ;; mapper 已打开：resume 状态（目标分区已存在）是
               ;; 预期且合法的；目标分区不存在却开着 mapper 才是
               ;; 活动安装残留（fail closed）。
               (if (file-exists? (by-partlabel-path "system"))
                 '(ok . "already open (resume state)")
                 (cons 'fail
                       "cryptroot mapper already in use but no target partitions found (an unfinished or active installation may exist)"))
               '(ok . #f)))))))

;;; ────────────────────────────────────────────────────────────
;;; 计划与确认输出（纯文本；打印归 blueprint）

(define (stage-action-line stage)
  "阶段状态 → 计划行文本。"
  (case (install-stage-status stage)
    ((fresh) "will run")
    ((complete) "already complete (skip)")
    ((resumable) "will resume (idempotent re-run)")
    ((ambiguous) "needs verification (open LUKS to resolve)")
    (else "BLOCKED (incompatible partial state)")))

;; Guile 3.0.11 的 (ice-9 format) 不支持 ~-Na 负宽度（"error in
;; format"），左对齐用手工补空格。
(define (pad-right s width)
  (string-append s (make-string (max 0 (- width (string-length s)))
                                #\space)))

(define (install-plan-lines state)
  "§9 格式的 INSTALL PLAN 文本行列表。"
  (append
   (list "INSTALL PLAN" ""
         (format #f "Host:   ~a" (install-state-host state))
         (format #f "Device: ~a" (install-state-device state))
         (if (install-state-device-model state)
           (format #f "Model:  ~a" (install-state-device-model state))
           "Model:  (unavailable)")
         "")
   (map (lambda (stage)
          (format #f "  [~a] ~a~a"
                  (symbol->string (install-stage-id stage))
                  (pad-right (symbol->string (install-stage-id stage)) 14)
                  (stage-action-line stage)))
        (install-state-stages state))
   (list ""
         "Destructive:"
         (format #f "  ~a will be erased" (install-state-device state))
         ""
         "Not included:"
         "  TPM enrollment"
         "  firmware Secure Boot PK enrollment"
         "")))

(define (install-confirm-lines state)
  "破坏性确认 UI 文本（§8：完整设备路径输入，其他输入/EOF 一律中止）。"
  (list
   ""
   (format #f "Target host:   ~a" (install-state-host state))
   (format #f "Target device: ~a" (install-state-device state))
   (format #f "Model: ~a~a"
           (or (install-state-device-model state) "(unavailable)")
           (if (install-state-device-facts state)
             (format #f " (~,2f GiB)"
                     (/ (device-facts-size (install-state-device-facts state))
                        1024.0 1024.0 1024.0))
             ""))
   ""
   (format #f "ALL DATA ON ~a WILL BE DESTROYED." (install-state-device state))
   ""
   "Type the full device path to continue:"))
(define (install-confirmed? input device)
  "只有逐字输入完整 DEVICE 才通过；空行/其他输入/EOF 一律不通过。"
  (and (string? input) (string=? input device)))

;;; ────────────────────────────────────────────────────────────
;;; 事务编排（root 阶段；dry-run 绝不调用）

;; exec: (lambda (argv) -> exit-status)，cwd = 仓库根。
;; on-confirm: (lambda (state) -> #t/#f)。

(define (make-cached-reader reader)
  "把 READER（0 参 thunk）缓存为一次读取。"
  (let ((value #f))
    (lambda ()
      (or value
          (let ((v (reader)))
            (set! value v)
            v)))))

(define (resolve-passphrase-reader! root)
  "LUKS passphrase 来源：identity（runtime 或 installed）就位时走
  age secret（decrypt 失败立即抛错，绝不回退交互）；否则交互两次
  确认。返回缓存 reader。"
  (make-cached-reader
   (resolve-luks-passphrase-source
    (if (or (runtime-identity-present?)
            (file-exists? (%installed-identity-path)))
      'luks-secret
      'interactive))))

(define (ensure-disk-phase! policy device passphrase)
  "fresh 盘的 disk 阶段：与 run-install 相同的执行序列（机制全部
  复用），但失败经 #:on-failure 回抛给事务分类，不做硬 exit。"
  (preflight-environment! device)
  (let ((policy-failures (validate-policy policy)))
    (unless (null? policy-failures)
      (error "host policy is invalid"
             (map check-failure-message policy-failures))))
  (format #t "probing ~a ...~%" device)
  (let ((failures (validate-target (probe-device device) policy)))
    (unless (null? failures)
      (error "target device failed safety checks"
             (map check-failure-message failures))))
  (let ((plan (storage-plan policy device)))
    (display-plan plan)
    (execute-plan plan
                  #:passphrase-reader passphrase
                  #:on-failure
                  (lambda (key args)
                    (error "disk phase step failed" key args))))
  (warn-if-store-in-ram))

(define (ensure-cow-store! exec target)
  "LiveCD 的 /gnu/store 在内存盘（tmpfs，或官方安装镜像的
  tmpfs-backed overlay）时，system init 前必须 herd start cow-store
  TARGET（否则构建写满内存盘）；herd 缺失即 fail closed（§28）。"
  (let ((fstype (false-if-exception
                 (first-command-line "findmnt" "-no" "FSTYPE"
                                     "/gnu/store"))))
    (when (member fstype '("tmpfs" "overlay"))
      (let ((herd (search-path
                   (string-split (or (getenv "PATH") "") #\:)
                   "herd")))
        (unless herd
          (error "cow-store required: /gnu/store is on tmpfs but 'herd' is missing; run the official installation environment"))
        (let ((status (exec `("herd" "start" "cow-store" ,target))))
          (unless (zero? status)
            (error "herd start cow-store failed" target status)))))))

(define (run-checked-exec! exec stage argv)
  "EXEC 运行 ARGV；非零退出码抛错（带阶段上下文）。"
  (format #t "  running: ~{ ~a~}~%" argv)
  (let ((status (exec argv)))
    (unless (zero? status)
      (error "subprocess failed" stage status argv))))

(define (resolve-primary-user-gid)
  "numeric gid of %primary-user 的 group，从安装器自身 group 数据库
解析（pinned Guix 的 system group id 自上而下确定分配，安装器与目标
系统同值；runbook 的 998 语义）。解析失败 fail closed——绝不猜测。"
  (let ((gid (false-if-exception
              (group:gid (getgrnam (user-profile-group %primary-user))))))
    (unless gid
      (error "cannot resolve gid for group" (user-profile-group %primary-user)))
    gid))

(define (install-repository! exec root target)
  "把仓库 checkout 复制到 /mnt/persist/data-home/USER/guix-configs
（installation.md 手动 runbook 阶段 10 的同一语义：tar 排除 vms/ 与
*.log，保留 .git）。两段 tar 经 staging 文件（/tmp）——EXEC 是单
argv 子进程，不经 shell 管道（无引号风险）。chown -R 归还 USER
ownership：boot 期 user-persistence activation 只 chown 顶层目录、
绝不递归（AGENT.md §5），内容 ownership 必须安装期定死。失败语义
与 secrets 阶段一致：幂等可重放，resume 自动重跑。"
  (let* ((dest (install-repo-path target))
         (staging (string-append (or (getenv "TMPDIR") "/tmp")
                                 "/guixcfg-repo-copy-"
                                 (number->string (getpid)) ".tar"))
         (owner (format #f "~a:~a"
                        (user-profile-uid %primary-user)
                        (resolve-primary-user-gid))))
    (run-checked-exec! exec 'repo `("mkdir" "-p" ,dest))
    (run-checked-exec! exec 'repo
                       `("tar" "cf" ,staging
                              "--exclude=./vms" "--exclude=*.log"
                              "-C" ,root "."))
    (run-checked-exec! exec 'repo `("tar" "xf" ,staging "-C" ,dest))
    (false-if-exception (delete-file staging))
    (run-checked-exec! exec 'repo `("chown" "-R" ,owner ,dest))
    (format #t "  repository copied to ~a~%" dest)))

(define* (install-transaction! root host device
                               #:key exec on-confirm
                                     (target "/mnt"))
         "执行安装事务（含 resume/skip/fail-closed 判定）。返回退出码
0/1/2/3（blueprint 的 root 命令原样 primitive-exit）。EXEC 契约见
模块头；ON-CONFIRM 是破坏性确认 UI（返回 #f = 用户中止）。"
         (if (not (zero? (getuid)))
           (begin
            (format (current-error-port)
                    "install transaction requires root (effective UID 0)~%")
            1)
           (let ((policy (storage-policy-by-name host))
                 (keydir (install-keydir target))
                 (mutated? #f))
             ;; ── preflight（任何 mutation 之前；失败 = 1）──
             (let ((preflight-ok?
                    (let ((failures
                           (filter-map
                            (lambda (check)
                              (match ((cdr check))
                                     (('fail . detail)
                                      (cons (car check) detail))
                                     (_ #f)))
                            (install-preflight-checks root host device))))
                      (if (null? failures)
                        #t
                        (begin
                         (for-each
                          (lambda (f)
                            (format (current-error-port)
                                    "preflight FAIL: ~a: ~a~%"
                                    (car f) (cdr f)))
                          failures)
                         #f)))))
               (if (not preflight-ok?)
                 1
                 (let* ((state (detect-install-state root host device))
                        (disk (stage-status state 'disk))
                        (disk-status (install-stage-status disk)))
                   (for-each (lambda (line) (format #t "~a~%" line))
                             (install-plan-lines state))
                   ;; ── 身份解锁（runbook 阶段 1 语义并入 blue
                   ;;    install；spec §15）：无 runtime/installed
                   ;;    identity 时交互解锁 master password——之后
                   ;;    disk 阶段的 LUKS passphrase 可走
                   ;;    luks-recovery.age（age 解密，无二次提示），
                   ;;    secrets 阶段也才能安装 identity。失败 = 1
                   ;;    （未 mutation）。已解锁/已安装则跳过。
                   (let ((unlock-ok?
                          (if (or (runtime-identity-present?)
                                  (file-exists?
                                   (install-identity-path target)))
                            #t
                            (begin
                             (format #t "~%== identity unlock~%")
                             (catch #t
                               (lambda ()
                                 (age-unlock!
                                  root
                                  (read-secret-line
                                   "Master password: "))
                                 #t)
                               (lambda (key . args)
                                 (format (current-error-port)
                                         "~%identity unlock failed; nothing was modified.~%error: ~s ~s~%"
                                         key args)
                                 #f))))))
                     (if (not unlock-ok?)
                       1
                       (cond
                     ((eq? disk-status 'incompatible)
                      (format (current-error-port)
                              "~%INSTALL BLOCKED: disk state is incompatible.~%  ~a~%"
                              (install-stage-detail disk))
                      (format (current-error-port)
                              "Expected: a blank device, or the complete target layout (esp+system partitions, LUKS2, Btrfs rootfs).~%Actual: see the stage report above.~%Recovery: inspect with 'guix repl tools/disk-install.scm -- inspect ~a'; wiping is never automatic.~%"
                              device)
                      2)
                     ((eq? disk-status 'ambiguous)
                      (format (current-error-port)
                              "~%INSTALL BLOCKED: disk state is ambiguous.~%  ~a~%"
                              (install-stage-detail disk))
                      (format (current-error-port)
                              "Recovery: open the volume manually ('cryptsetup open ~a cryptroot') and re-run; wiping is never automatic.~%"
                              (by-partlabel-path "system"))
                      2)
                     ((and (eq? disk-status 'fresh)
                           (not (on-confirm state)))
                      (format (current-error-port)
                              "~%Installation aborted; nothing was modified.~%")
                      3)
                     (else
                      (when (eq? disk-status 'fresh)
                        (format #t "~%Confirmation accepted.~%"))
                      ;; ── 分阶段执行 ──
                      (catch #t
                        (lambda ()
                          (let ((run-stage
                                 (lambda (id thunk)
                                   (let ((s (stage-status
                                             (detect-install-state root host
                                                                   device)
                                             id)))
                                     (format #t "~%== stage ~a: ~a~%" id
                                             (install-stage-status s))
                                     (case (install-stage-status s)
                                       ((complete) #t)
                                       ((incompatible)
                                        (error "stage is incompatible"
                                               (install-stage-detail s)))
                                       ((ambiguous)
                                        (error "stage is ambiguous"
                                               (install-stage-detail s)))
                                       (else (thunk)))))))
                            ;; 1. disk（fresh：完整磁盘阶段）
                            (run-stage 'disk
                                       (lambda ()
(set! mutated? #t)
                                         (let ((passphrase
                                                (resolve-passphrase-reader!
                                                 root)))
                                           ;; fail-early：luks-secret
                                           ;; 解密预演（首次 mutation 前）
                                           (passphrase)
                                           (ensure-disk-phase!
                                            policy device passphrase))))
                            ;; 2. mounts（resume：打开 LUKS + 重放
                            ;;    mount 步骤）
                            (run-stage 'mounts
                                       (lambda ()
                                         (let ((passphrase
                                                (resolve-passphrase-reader!
                                                 root)))
                                           (unless (file-exists?
                                                    %luks-mapper-path)
                                             (format #t "  opening LUKS volume...~%")
                                             (execute-luks-open
                                              (passphrase)))
                                           (execute-mounts!
                                            (storage-plan policy device)))))
                            ;; 3. facts（幂等重写；不匹配时分类层已
                            ;;    blocked）
                            (run-stage 'facts
                                       (lambda ()
                                         (write-machine-facts target)))
                            ;; 4. sb-keys（keygen 子进程；partial 已
                            ;;    blocked）
                            (run-stage 'sb-keys
                                       (lambda ()
                                         (run-checked-exec!
                                          exec 'sb-keys
                                          (sb-keygen-tool-argv
                                           root keydir))))
                            ;; 5. secrets（幂等）
                            (run-stage 'secrets
                                       (lambda ()
                                         (ensure-installed-identity! target)
                                         (parameterize
                                          ((%account-credentials-dir
                                            (string-append
                                             target
                                             (persist-mount-point
                                              "@persist-system")
                                             "/accounts")))
                                           (provision-password-hash!
                                            (user-profile-name %primary-user)
                                            (string-append
                                             root "/"
                                             %user-password-hash-rel)))
                                         (format #t "  secrets installed.~%")))
                            ;; 6. sb-keystore（幂等重建）
                            (run-stage 'sb-keystore
                                       (lambda ()
                                         (run-checked-exec!
                                          exec 'sb-keystore
                                          (sb-keystore-tool-argv
                                           root keydir))))
                            ;; 7. system-init（重跑安全；facts 经 env）
                            (run-stage 'system-init
                                       (lambda ()
                                         (ensure-cow-store! exec target)
                                         (setenv "GUIX_CONFIG_FACTS"
                                                 (install-facts-path target))
                                         (set! mutated? #t)
                                         (run-checked-exec!
                                          exec 'system-init
                                          (system-init-argv root host))))
                            ;; 8. commit-root（CLI 子进程隔离硬 exit；
                            ;;    幂等 + 中断恢复）
                            (run-stage 'commit-root
                                       (lambda ()
                                         (run-checked-exec!
                                          exec 'commit-root
                                          (commit-root-tool-argv
                                           root target))))
                            ;; 9. repo（runbook 阶段 10 机制化：
                            ;;    checkout → @persist-data-home；幂等）
                            (run-stage 'repo
                                       (lambda ()
                                         (install-repository!
                                          exec root target))))
                            ;; 10. validate（总是执行）
                            (format #t "~%== stage validate~%")
                            (let ((problems
                                   (validate-installation target device)))
                              (if (null? problems)
                                (begin
                                 (for-each
                                  (lambda (l) (format #t "~a~%" l))
                                  (install-next-step-lines host))
                                 0)
                                (begin
                                 (for-each
                                  (lambda (p)
                                    (format (current-error-port)
                                            "validate FAIL: ~a~%" p))
                                  problems)
                                 (format (current-error-port)
                                         "~%Installation is incomplete; fix the issues above or re-run 'blue install ~a ~a' (resume is automatic where safe).~%"
                                          host device)
                                  2))))
                        (lambda (key . args)
                          (format (current-error-port)
                                  "~%Installation stopped.~%error: ~s ~s~%"
                                  key args)
                          (format (current-error-port)
                                  "~%Recovery: re-run 'blue install ~a ~a' — completed stages are detected and skipped; the disk is never re-formatted automatically.~%"
                                   host device)
                           (if mutated? 2 1)))))))))))))

;;; ────────────────────────────────────────────────────────────
;;; 安装后验证（§37；只读）

(define (validate-installation target device)
  "返回问题字符串列表（空 = 通过）。只读。"
  (filter-map
   (lambda (check)
     (match check
            ((#f . problem) problem)
            (_ #f)))
   (list
    (cons (file-exists? (string-append target "/etc"))
          (format #f "~a/etc missing (system init incomplete)" target))
    (cons (file-exists? (string-append target "/boot/deploy-uki"))
          "boot/deploy-uki missing (system init incomplete)")
    (cons (file-exists? (install-facts-path target))
          "machine facts file missing")
    (cons (and (file-exists? (install-facts-path target))
               (let ((facts (false-if-exception
                             (load-machine-facts
                              (install-facts-path target)))))
                 (and facts (assq-ref facts 'luks-uuid))))
          "machine facts lack the boot-critical luks-uuid")
    (cons (every (lambda (f)
                   (file-exists?
                    (string-append target %esp-mount-point f)))
                 %esp-markers)
          "ESP boot artifacts missing (limine.conf or UKI slots)")
    (cons (file-exists? (install-identity-path target))
          "installed stable identity missing")
    (cons (file-exists?
           (install-password-hash-path target
                                       (user-profile-name %primary-user)))
          "password hash missing")
    (cons (file-exists?
           (string-append target
                          (persist-mount-point "@persist-system")
                          "/root-generations/state.scm"))
          "root generation not committed (state.scm missing)")
    (cons (repo-copy-present? target)
          "repository checkout missing under @persist-data-home (repo stage incomplete)")
    (cons (not (file-exists?
                (string-append (install-repo-path target) "/vms")))
          "vms/ leaked into the persistent repository copy")
    (cons (sb-key-material-complete? target)
          "Secure Boot key material incomplete (key files or keystore missing)"))))

(define (install-next-step-lines host)
  "§39 的收尾文案（绝不自动 reboot）。"
  (list ""
        "Installation complete."
        ""
        "Next step: shut down, reboot into the installed system, then run:"
        (format #f "  blue firstboot ~a" host)
        ""
        "Do not reboot automatically; shut down the installer cleanly first."))
