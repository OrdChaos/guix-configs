;;; Guix system generation 回收模型（blue gc 的域逻辑）。
;;;
;;; 与 Btrfs root generation（storage/root-generation.scm）正交，但共用
;;; 同一保留算法与同一 host policy：
;;;   storage/root-generation.scm  → 磁盘上的 @root-N 子卷（Btrfs 轴）
;;;   本模块                        → /var/guix/profiles/system-N-link
;;;                                   （声明式系统轴）
;;; 两轴都经 generations-to-delete* 保留 current + last-good，再保留最新
;;; KEEP 个（KEEP = host storage policy 的 keep-root-generations）——
;;; 同一 n 在两轴语义一致。
;;;
;;; 本模块只删 profile generation（即删除 GC root），**不运行 `guix gc`**：
;;; 删除 root 本身不释放 store 空间；真正回收 store 需要显式 `guix gc`。
;;; 有意不自动 `guix gc`——它会连带回收所有失去 root 的 on-demand store
;;; 内容（例如 guix-rust-toolchain 代理 realize 的 toolchain：其 GC root
;;; 在 ephemeral 的 ~/.cache/guix-rust-toolchain/roots/，跨 boot 即失效）。
;;; store 空间由操作者按需显式回收。
;;;
;;; 为什么不用 `guix system delete-generations`（决策记录）：pinned Guix
;;; 的该命令删完 generation 后调用 reinstall-bootloader，后者经
;;; lookup-bootloader-by-name 在【当前 profile 的 gnu/bootloader 模块】
;;; 里查找 system boot parameters 记录的 bootloader 名。本系统用仓库内
;;; 自定义 uki-bootloader（name = uki，guixcfg/boot/uki-bootloader.scm），
;;; 不在 profile 的 gnu/bootloader 命名空间——查找必然失败
;;; （"uki: no such bootloader"）。因此改用
;;; `guix package -p <system-profile> --delete-generations=PATTERN`：
;;; 复用同一个 delete-matching-generations 实现（含 current 保护、
;;; generation 0 保护），但不触碰 bootloader（系统菜单本就不列历史
;;; @root，见 storage.md）。
;;;
;;; last-good system 的 GC root（/var/guix/gcroots/guixcfg/last-good-system）
;;; 由 boot-state/recovery 维护；本模块只保护它的 generation link 不被删。
;;;
;;; 本模块只读文件系统 + 纯决策 + argv 构造（不执行子进程）：执行在
;;; tools/gc-cli.scm（pinned 子进程；blueprint 编译期不导入本模块，
;;; 见 gsettings/install/enroll 同款决策）。

(define-module (guixcfg system system-generations)
               #:use-module (guixcfg storage model)       ; host-storage-policy-keep-root-generations
               #:use-module (guixcfg storage policies)    ; storage-policy-by-name
               #:use-module (guixcfg storage root-generation) ; generations-to-delete*
               #:use-module (guixcfg boot boot-state)     ; %boot-states-path、read-boot-state-alist
               #:use-module (ice-9 ftw)                   ; scandir
               #:use-module (ice-9 regex)                 ; make-regexp、regexp-exec
               #:use-module (ice-9 format)
               #:use-module (srfi srfi-1)
               #:use-module (srfi srfi-13)
               #:export (%system-profile
                         system-generation-numbers
                         system-current-generation
                         last-good-system-generation
                         system-generations-to-delete
                         keep-for-host
                         parse-generation-list
                         delete-generations-argv
                         system-generation-plan))

;; 运行系统视角的 system profile（Guix 惯例固定路径）。
(define %system-profile "/var/guix/profiles/system")

;;; ────────────────────────────────────────────────────────────
;;; 文件系统读取（只读；测试可传自定义 profile 路径）

(define (system-generation-numbers profile)
  "PROFILE 下实际存在的 system generation 编号（升序）。PROFILE 目录
不存在/不可读时返回 '()。"
  (let* ((dir (dirname profile))
         (base (basename profile))
         (rx (make-regexp
              (string-append "^" (regexp-quote base) "-([0-9]+)-link$"))))
    (sort (filter-map
           (lambda (name)
             (let ((m (regexp-exec rx name)))
               (and m (string->number (match:substring m 1)))))
           (or (false-if-exception (scandir dir)) '()))
          <)))

(define (system-current-generation profile)
  "PROFILE 当前指向的 generation 编号；无法解析（非 symlink / 格式不符）
返回 #f。"
  (let* ((target (false-if-exception (readlink profile)))
         (rx (make-regexp
              (string-append (regexp-quote (basename profile))
                             "-([0-9]+)-link$")))
         (m (and target (regexp-exec rx (basename target)))))
    (and m (string->number (match:substring m 1)))))

(define* (last-good-system-generation #:optional (path %boot-states-path))
         "boot-state 注册表记录的 last-good Guix generation 编号；缺失/无效
返回 #f。兼容 v2（last-good 是 alist）与 v1（last-good 是整数）。"
         (let ((alist (false-if-exception (read-boot-state-alist path))))
           (and alist
                (let ((lg (assq-ref alist 'last-good)))
                  (cond ((and (list? lg) (assq 'generation lg))
                         (assq-ref lg 'generation))
                    ((integer? lg) lg)
                    (else #f))))))

;;; ────────────────────────────────────────────────────────────
;;; 决策

(define (system-generations-to-delete existing current last-good keep)
  "EXISTING 升序 generation 编号；保留 current、last-good 与其余中最新
KEEP 个，返回应删除编号（升序）。复用 Btrfs 轴同一算法。"
  (generations-to-delete* existing current last-good keep))

(define (keep-for-host host)
  "HOST 的 storage policy 保留数（keep-root-generations）。未知 host 报错
（fail closed，不 fallback）。"
  (unless (or (string? host) (symbol? host))
    (error "host is required to resolve the retention policy" host))
  (let ((policy (storage-policy-by-name host)))
    (unless policy
      (error "unknown host storage policy" host))
    (host-storage-policy-keep-root-generations policy)))

(define (parse-generation-list str)
  "解析 \"1,2,3\" / \"1..3\" / \"1..\" / \"..3\" 为升序编号列表（去重）。
空串/非法 token 报错（fail closed）。"
  (define (parse-token token)
    (cond
      ((string-match "^([0-9]+)$" token)
       (list (string->number (match:substring
                              (string-match "^([0-9]+)$" token) 1))))
      ((string-match "^([0-9]+)\\.\\.([0-9]+)$" token)
       (let* ((m (string-match "^([0-9]+)\\.\\.([0-9]+)$" token))
              (a (string->number (match:substring m 1)))
              (b (string->number (match:substring m 2))))
         (unless (<= a b)
           (error "invalid generation range" token))
         (iota (1+ (- b a)) a)))
      (else
       (error "invalid generation number" token))))
  (let ((tokens (string-split (string-trim-both str) #\,)))
    (when (or (null? tokens) (any string-null? tokens))
      (error "empty generation list"))
    (sort (delete-duplicates (append-map parse-token tokens)) <)))

;;; ────────────────────────────────────────────────────────────
;;; argv 构造（纯函数；执行在 tools/gc-cli.scm）

(define (delete-generations-argv profile generations)
  "删除 GENERATIONS（非空）的 argv。用 guix package 而非 guix system
delete-generations（后者会 reinstall-bootloader，见模块头注释）。"
  (unless (pair? generations)
    (error "no generations to delete"))
  `("guix" "package" "-p" ,profile
           ,(string-append "--delete-generations="
                           (string-join (map number->string generations) ","))))

;;; ────────────────────────────────────────────────────────────
;;; plan（只读决策；供 plan 显示与 run 执行共用）

(define* (system-generation-plan #:key
                                 (profile %system-profile)
                                 (boot-states-path %boot-states-path)
                                 (host #f)
                                 (keep #f)
                                 (delete #f))
         "计算回收计划（不修改任何状态），返回 alist：
  existing / current / last-good / mode / keep / to-delete
MODE 是 'keep（按策略或 --keep N）或 'delete（--delete 显式集合）。
显式 --delete 必须存在且不得包含 current / last-good（fail closed）；
显式集合与 --keep 互斥。"
         (when (and delete keep)
           (error "--delete and --keep are mutually exclusive"))
         (let* ((existing (system-generation-numbers profile))
                (current (system-current-generation profile))
                (last-good (last-good-system-generation boot-states-path)))
           (if delete
             (let ((delete (sort (delete-duplicates delete) <)))
               (when (null? delete)
                 (error "--delete requires at least one generation"))
               (for-each
                (lambda (g)
                  (unless (memv g existing)
                    (error "generation does not exist" g))
                  (when (or (and current (eqv? g current))
                            (and last-good (eqv? g last-good)))
                    (error "refusing to delete current/last-good generation" g)))
                delete)
               `((existing . ,existing)
                 (current . ,current)
                 (last-good . ,last-good)
                 (mode . delete)
                 (keep . #f)
                 (to-delete . ,delete)))
             (let ((keep (if keep keep (keep-for-host host))))
               (unless (and (integer? keep) (>= keep 0))
                 (error "keep must be a non-negative integer" keep))
               `((existing . ,existing)
                 (current . ,current)
                 (last-good . ,last-good)
                 (mode . keep)
                 (keep . ,keep)
                 (to-delete . ,(system-generations-to-delete
                                existing current last-good keep)))))))
