;;; blueprint.scm —— Blue 任务运行器（仓库编排入口，Phase 1）。
;;;
;;; 定位（设计决策记录）：Blue = repository orchestrator。只做日常入口、
;;; 编排、部署前置护栏、dry-run 契约与 test runner 接入；gate 事务机制
;;; 事实源是 (guixcfg system reconfigure)（Guile 实现），其余机制在
;;; (guixcfg ...) modules；独立工具（disk-install / tpm2-enroll /
;;; secure-boot / secrets）保持独立，不在此包装。
;;;
;;; 结构：
;;;   §0 子进程出口 —— %run（统一 dry-run 短路）/ %exec / %capture
;;;   §1 命令构造复用层 —— 直接使用 (guixcfg system deploy) 的纯 argv
;;;   §2 preflight —— doctor（含 git clean gate）与 build preflight（不含）
;;;   §3 命令定义 —— doctor / build-os / reconfigure（+ 内部
;;;                    privileged mode）/ update / flatpak
;;;   §4 repository-tests testable —— 薄包装 tests/run-tests.scm
;;;   §5 入口 —— (blueprint ...) 注册
;;;
;;; Host 语义：EXPLICIT HOST ONLY。host ID 事实来自
;;; modules/guixcfg/hosts/*.scm 的文件名（(guixcfg hosts selection)
;;; 目录枚举），无自动检测、无 fallback。
;;;
;;; dry-run 契约（逐命令，见 docs/operations/reconfigure.md）：
;;;   build-os -n   → 下游 guix system build --dry-run（真 derivation plan）
;;;   reconfigure -n → 下游 guix system reconfigure --dry-run；
;;;                    绝不进入 privileged transaction（无 sudo、无
;;;                    gate、无 herd、无 Home 热激活）
;;;   update -n     → command preview only（不联网、不写锁、无未来 revision）
;;;   check -n      → Blue 内建语义：不真正运行测试套件
;;;   doctor        → 本身只读，检查照常执行
;;;   flatpak -n    → status 真实执行（只读）；sync/update/
;;;                   update-runtimes 真实只读 plan；remove/
;;;                   remote-replace 目标预览；gc 仅 command
;;;                   preview（一律绝不修改 Flatpak 状态）
;;;
;;; 运行前提（Phase 0）：blue 经 bluebox 频道 + development manifest 提供：
;;;   guix time-machine -C channels.lock.scm -- \
;;;     shell -m manifests/development.scm -- blue <command>

(use-modules (blue states)                  ; dry-build?
             (blue build)                   ; make-build-manifest
             (blue subprocess)              ; popen
             (blue types)                   ; define-blue-class / define-blue-method
             (blue types blueprint)
             (blue types buildable)         ; ask-build-manifest
             (blue types command)           ; define-command
             (blue types testable)          ; <testable>
             (blue file-system directory)   ; mkdir-p
             (ice-9 match)
             (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-26))

;;; ============================================================
;;; §0 子进程出口
;;; ============================================================

;; 仓库根：Blue 的 source directory 状态 = blueprint 所在目录。
;; 比 getcwd 可靠（blue 可能从父目录经 ../blueprint.scm 调用）。
;; 仓库根的另一权威解析 (guixcfg utils repository-source) 保留给模块内使用。
(define (%repo-root)
  #%?srcdir)

;; 先确保 (guixcfg ...) 可解析：blue 只自动把 blueprint 所在目录加入
;; %load-path，modules/ 需要显式加入。必须经 add-to-load-path 宏的
;; expand-time 效应——blue 的编译期 use-modules 解析要求路径在展开时
;; 已生效；而 #%?srcdir 状态在展开期不可用（(%repo-root) 只能运行时
;; 求值），若把计算放进该宏的参数会触发 guile 编译器 out-of-range
;; 崩溃（guile 3.0.11 + blue 实测）。blue 加载 blueprint 前已把其所在
;; 目录（= 仓库根）放入 %load-path，从这里反查含 channels.lock.scm
;; 的目录（与 (guixcfg utils repository-source) 的 marker 约定一致），
;; 全程纯文件操作，展开期可安全求值。
(add-to-load-path
 (string-append
  (car (filter (lambda (dir)
                 (and (string? dir)
                      (file-exists? (string-append dir "/channels.lock.scm"))))
               %load-path))
  "/modules"))

;; 引导 guix 自身的 Guile 模块树（source + compiled）：
;; (guixcfg ...) 模块经 (guix records)/(guix gexp)/(guix build utils)
;; 依赖 guix 的模块树。deployed system 的 login shell 与 time-machine
;; shell 经 profile search paths（GUILE_LOAD_PATH /
;; GUILE_LOAD_COMPILED_PATH）已提供；裸环境（PATH 上的 Home-installed
;; blue、非 login shell）则按 guix 的标准安装位置在尾部追加。
;; 尾部追加不会遮蔽 pinned 版本（search-path 按序命中在先的
;; GUILE_LOAD_PATH 条目），因此无需"已提供则跳过"的展开期判断。
;;
;; 路径构造不写死版本号：profile 根（/run/current-system/profile 是
;; guix system 常量，~/.guix-profile 与 ~/.config/guix/current 是
;; guix 自身惯例）之下按 guile 标准布局拼接，版本分量取运行中
;; guile 的 (effective-version)——与 guix 自己的 wrapper 脚本同款
;; 拼法。这也正好是 ABI 语义：该目录下的 .go 只能被同 effective
;; version 的 guile 加载，跟随 blue 运行的 guile 即跟随正确的树。
;;
;; 实现约束（guile 3.0.9/3.0.11 + blue 实测，最小复现二分）：
;;   1. 必须展开期生效（blue 编译期 use-modules 解析），参数必须
;;      展开期可求值：getenv/string-append/file-exists?/filter/
;;      effective-version 实测安全，#%?srcdir 状态不可（见上）。
;;   2. 只能用【内联】eval-when (expand load eval) + let/filter/
;;      append 逐项实现。以下写法都会在 link 阶段触发 guile
;;      out-of-range（(77 79 80) (80)，复现率 10/10）：
;;        - 在本文件自定义的 eval-when 展开期 body 里读取
;;          %load-path（内建 add-to-load-path 自身的展开期语义
;;          豁免——见上方 modules/ 解析的 marker 扫描）；
;;        - 用 define-syntax 自定义宏包 eval-when（with-syntax
;;          拼接同理触发）；
;;        - syntax-case 模板里 #` + #,pattern-var（该写法本身即
;;          失效语法，报 "reference to pattern variable outside
;;          syntax form"）。
;;   3. 裸环境崩溃的触发链：use-modules 解析到 guix 源码 →
;;      编译期嵌套 auto-compile guix 模块树 → 外层 link 阶段
;;      out-of-range（用户 ccache 不在裸环境 %load-compiled-path
;;      上，永远无法变热）。因此 compiled 路径必须与 source 路径
;;      同时在展开期就位，让 guix 模块一律命中已编译 .go。
;;   4. 目录按 deployed system → ~/.guix-profile → guix current
;;      的顺序尾部追加，source 与 compiled 同序，保证 .scm/.go
;;      配对来自同一棵树。
(eval-when (expand load eval)
  (let ((guile-version (effective-version))
        (profile-roots
         (filter (lambda (root)
                   (and (string? root) (file-exists? root)))
                 (list "/run/current-system/profile"
                       (string-append (getenv "HOME") "/.guix-profile")
                       (string-append (getenv "HOME") "/.config/guix/current")))))
    (let ((src-dirs
           (filter (lambda (dir)
                     (and (string? dir) (file-exists? dir)))
                   (map (lambda (root)
                          (string-append root "/share/guile/site/" guile-version))
                        profile-roots)))
          (cmp-dirs
           (filter (lambda (dir)
                     (and (string? dir) (file-exists? dir)))
                   (map (lambda (root)
                          (string-append root "/lib/guile/" guile-version
                                         "/site-ccache"))
                        profile-roots))))
      (set! %load-path (append %load-path src-dirs))
      (set! %load-compiled-path (append %load-compiled-path cmp-dirs)))))

(use-modules (guixcfg system deploy)        ; argv 构造 / 解析 / 只读检查素材 / host 枚举
             (guixcfg system reconfigure)   ; gate transaction（privileged mode 执行）
             (guixcfg utils channels)       ; channel 结构比较（update 摘要）
             (guixcfg utils atomic-file)    ; atomic-write-file!（锁重写）
             (guixcfg flatpak reconcile)    ; Flatpak 域操作与 dry-run plan
             (guixcfg flatpak model)        ; Flatpak 访问器（dry-run 输出）
             (guixcfg flatpak registry)     ; %flatpak-remotes/applications/selection
             (guixcfg users facts))         ; %primary-user（HOME_USER 默认权威源；channel-free）

(define (%subprocess-fail! status command)
  "子进程非零退出的统一出口：以子进程退出码终止（primitive-exit 不做
Guile backtrace——非零退出是预期内失败）。"
  (format (current-error-port) "command failed (exit ~a): ~{ ~a~}~%" status command)
  (primitive-exit (or status 1)))

(define* (%run command #:key working-directory)
         "唯一允许启动子进程的通用出口。blue --dry-run 时只打印不执行；
正常模式执行，非零退出即失败。WORKING-DIRECTORY 非 #f 时先 chdir
（guix repl 的测试入口需要仓库根 CWD 解析相对路径）。"
         (if (dry-build?)
           (begin
            (format #t "  [dry-run] ~{ ~a~}~%" command)
            #t)
           (let ((status (popen (car command) (cdr command)
                                #:working-directory working-directory)))
             (unless (zero? status)
               (%subprocess-fail! status command))
             #t)))

(define (%exec command)
  "总是真实执行（无 dry-run 短路）。只允许用于 Blue dry-run 映射到
下游 Guix dry-run 的两个特殊路径：build-os -n / reconfigure -n——
执行的命令自带 guix --dry-run，无副作用（pinned Guix 的 build-handler
只累积请求不执行）。其余一切子进程必须走 %run。"
  (let ((status (popen (car command) (cdr command)
                       #:working-directory (%repo-root))))
    (unless (zero? status)
      (%subprocess-fail! status command))
    #t))

(define (%capture command)
  "运行命令并捕获 stdout，返回 (values output status)。用于纯只读
preflight（git status / describe 等）——blue -n 下也真实执行，以提供
有效验证。调用方负责检查 status。"
  (let ((port (open-output-string)))
    (let ((status (popen (car command) (cdr command) #:output port
                         #:working-directory (%repo-root))))
      (values (get-output-string port) status))))

(define (in-path? program)
  "PROGRAM 是否在 PATH 中（search-path 语义，不做 shell 查找）。"
  (and=> (search-path (string-split (or (getenv "PATH") "") #\:) program)
         (const #t)))

;;; ============================================================
;;; §1 参数校验
;;; ============================================================

;; 命令体内的参数校验禁止 (error ...)：blue 的 backtrace 打印器对含
;; 多字节注释的源文件做列偏移截取时会在 guile 3.0.11 触发
;; out-of-range 崩溃（实测）。统一走 %usage-error：打印可执行信息 +
;; primitive-exit 1（与 tools/reconfigure.sh 的 CLI 惯例一致）。
(define (%usage-error message)
  (format (current-error-port) "~a~%" message)
  (primitive-exit 1))

;; guile 3.0.11 的 error 异常参数形态是 (key format-string irritants ...)，
;; 消息可能嵌在 irritants 里；提取其中全部字符串与符号（对 misc-error
;; 内部布局不敏感），供 catch 后转为单行错误输出。
(define (exception-strings exn-args)
  (let walk ((x exn-args))
    (cond ((string? x) (list x))
      ((symbol? x) (list (symbol->string x)))
      ((pair? x) (append (walk (car x)) (walk (cdr x))))
      (else '()))))

(define (%require-host-argument arguments)
  "位置参数必须恰好是一个已知 HOST（fail closed，列出可用 host）。"
  (match arguments
         ((host)
          (if (host-id? (known-host-ids (%repo-root)) host)
            host
            (%usage-error
             (format #f "unknown host: ~a~%known hosts: ~a~%usage: blue <command> HOST"
                     host (string-join (known-host-ids (%repo-root)) ", ")))))
         (_ (%usage-error
             (format #f "expected exactly one HOST argument; known hosts: ~a"
                     (string-join (known-host-ids (%repo-root)) ", "))))))

(define (build-os-hosts root arguments)
  "build-os 的 HOST|all 解析。绝不无参 fallback。"
  (match arguments
         (("all") (known-host-ids root))
         ((host)
          (if (host-id? (known-host-ids root) host)
            (list host)
            (%usage-error
             (format #f "unknown host: ~a~%known hosts: ~a~%usage: blue build-os HOST | all"
                     host (string-join (known-host-ids root) ", ")))))
         (_ (%usage-error
             (format #f "expected HOST or all; known hosts: ~a"
                     (string-join (known-host-ids root) ", "))))))

;;; ============================================================
;;; §2 preflight
;;; ============================================================

;; checks 是 ((label . thunk)) 列表；thunk 返回 (ok . detail) 或
;; (fail . detail)。全部失败时打印汇总并 exit 1（fail closed）。
(define (%run-checks title checks)
  (format #t "~a~%" title)
  (let loop ((checks checks) (failures 0))
    (if (null? checks)
      (begin
       (if (zero? failures)
         (format #t "  all checks passed~%")
         (begin
          (format (current-error-port)
                  "preflight: ~a check(s) failed~%" failures)
          (primitive-exit 1)))
       #t)
      (let* ((check (car checks))
             (result ((cdr check))))
        (match result
               ((status . detail)
                (format #t "  [~a] ~a~a~%"
                        (if (eq? status 'ok) "OK" "FAIL")
                        (car check)
                        (if detail (string-append ": " detail) ""))
                (loop (cdr checks)
                      (+ failures (if (eq? status 'ok) 0 1)))))))))

(define (%root-level-checks root)
  "与 host 无关的构建/部署公共前置（不含 git clean）。"
  (list
   (cons "repository root"
         (lambda ()
           (if (and (absolute-file-name? root)
                    (file-exists? (string-append root "/channels.lock.scm")))
             '(ok . #f)
             (cons 'fail (string-append "bad repository root: " root)))))
   (cons "channels.lock.scm readable"
         (lambda ()
           (if (file-exists? (string-append root "/channels.lock.scm"))
             '(ok . #f)
             '(fail . "channels.lock.scm missing"))))
   (cons "modules directory"
         (lambda ()
           (if (file-exists? (string-append root "/modules"))
             '(ok . #f)
             '(fail . "modules/ missing (guix -L target)"))))
   (cons "machine facts"
         (lambda ()
           (match (facts-resolution-report)
                  (('ok . _) '(ok . #f))
                  (('none) (cons 'fail
                                 "no machine facts (set GUIX_CONFIG_FACTS or install to /persist)"))
                  (('invalid . message) (cons 'fail message)))))
   (cons "tools (guix git sudo)"
         (lambda ()
           (let ((missing (filter (negate in-path?) '("guix" "git" "sudo"))))
             (if (null? missing)
               '(ok . #f)
               (cons 'fail (string-append "missing in PATH: "
                                          (string-join missing ", ")))))))))

;; build preflight：允许 dirty worktree，因此不得包含 git clean。
(define (%build-preflight root host)
  (unless (file-exists? (host-source-absolute-path root host))
    (format (current-error-port) "preflight: host file missing: ~a~%"
            (host-source-absolute-path root host))
    (primitive-exit 1))
  (%run-checks
   (format #f "build preflight (host: ~a; dirty worktree allowed)~%" host)
   (%root-level-checks root)))

;; doctor：deployment readiness——比 build preflight 多 git clean 与
;; channel 结构兼容。完全离线。
(define (%doctor root host)
  (format #t "doctor: deployment readiness for host ~a~%" host)
  (%run-checks
   (format #f "doctor checks (repo: ~a)~%" root)
   (append
    (%root-level-checks root)
    (list
     (cons "host id known"
           (lambda ()
             (if (host-id? (known-host-ids root) host)
               (cons 'ok host)
               (cons 'fail
                     (string-append "unknown host; known hosts: "
                                    (string-join (known-host-ids root) ", "))))))
     (cons "host file present"
           (lambda ()
             (if (file-exists? (host-source-absolute-path root host))
               (cons 'ok (host-source-relative-path host))
               (cons 'fail (host-source-absolute-path root host)))))
     (cons "git worktree clean"
           (lambda ()
             (call-with-values
              (lambda () (%capture (git-status-porcelain-argv root)))
              (lambda (out status)
                (cond ((not (zero? status))
                       (cons 'fail "git status failed"))
                  ((porcelain-output-clean? out)
                   '(ok . #f))
                  (else
                   (cons 'fail
                         "dirty worktree: deployment requires a clean committed worktree (build-os is allowed on dirty)")))))))
     (cons "channels structure compatible"
           (lambda ()
             (if (channels-structure-ok? root)
               '(ok . "name/url/branch/introduction match; revision not compared")
               '(fail . "channels.scm and channels.lock.scm disagree structurally"))))))))

;; 记录当前 HEAD 供 reconfigure 后漂移检查；输出用于 doctor 报告。
(define (%head-commit root)
  (call-with-values
   (lambda () (%capture (git-head-commit-argv root)))
   (lambda (out status)
     (and (zero? status) (trimmed-command-output out)))))

(define (%postflight-drift root head-before)
  "reconfigure 成功后复查 HEAD 与 worktree；漂移只 WARNING（不改变
已完成的部署）。"
  (let ((head-after (%head-commit root)))
    (when (and head-before head-after
               (not (string=? head-before head-after)))
      (format (current-error-port)
              "WARNING: HEAD moved during reconfigure (~a -> ~a); the deployed commit differs from the preflight commit~%"
              head-before head-after)))
  (call-with-values
   (lambda () (%capture (git-status-porcelain-argv root)))
   (lambda (out status)
     (when (and (zero? status) (not (porcelain-output-clean? out)))
       (format (current-error-port)
               "WARNING: worktree became dirty during reconfigure~%")))))

;;; ============================================================
;;; §3 命令定义
;;; ============================================================

(define-command (doctor-command arguments)
                ((invoke "doctor")
                 (category 'maintenance)
                 (synopsis "Deployment readiness check for HOST (offline, read-only)")
                 (help "HOST
Check whether the repository and this machine satisfy the deployment
preconditions for HOST. Fails closed when the git worktree is dirty.
Completely offline: never queries upstream for channel updates."))
                (let* ((root (%repo-root))
                       (host (%require-host-argument arguments)))
                  (let ((head (%head-commit root)))
                    (%doctor root host)
                    (when head
                      (format #t "  HEAD: ~a~%" head)))))

(define-command (build-os-command arguments)
                ((invoke "build-os")
                 (category 'deployment)
                 (synopsis "Build system configuration for HOST | all (dirty worktree allowed)")
                 (help "HOST | all
Build Guix system configurations via guix time-machine -C channels.lock.scm.
Dirty worktree is allowed (no git gate). With blue -n, maps to
guix system build --dry-run: derivation plan only, no store objects."))
                (let* ((root (%repo-root))
                       (hosts (build-os-hosts root arguments)))
                  (for-each (lambda (host)
                              (%build-preflight root host)
                              (if (dry-build?)
                                (%exec (system-build-argv root host #:dry-run? #t))
                                (%run (system-build-argv root host))))
                            hosts)))

(define-command (reconfigure-command arguments)
                ((invoke "reconfigure")
                 (category 'deployment)
                 (synopsis "Deploy the system for HOST (clean committed worktree required)")
                 (help "HOST
Doctor preflight (including the git clean gate), then hand off to a
privileged re-execution of this same Blue (sudo <this-blue> -f
<blueprint> .reconfigure-root HOST HOME-USER) running the
(guixcfg system reconfigure) gate transaction, then check for
HEAD/worktree drift. Exit codes: 0 full success; 1 system reconfigure
failed (gate reopened); 2 system switched but Home/readiness failed
(gate remains closed).
With blue -n: validates the Guix system derivation/build plan only; it
does not enter the privileged transaction (no sudo, no gate, no
Shepherd restart, no Home hot activation)."))
                (let* ((root (%repo-root))
                       (host (%require-host-argument arguments)))
                  (if (dry-build?)
                    (begin
                     (%doctor root host)        ; 只读前置（含 git clean）在 -n 下照常执行
                     (%exec (system-reconfigure-dry-run-argv root host)))
                    (begin
                     (%doctor root host)
                     (let ((head-before (%head-commit root)))
                       ;; privilege handoff：sudo 重新执行【同一个】Blue
                       ;; executable（绝对路径），root phase 运行 Guile
                       ;; transaction 并原样返回 exit code（0/1/2）。
                       (%run (reconfigure-privileged-argv
                              (car (program-arguments))
                              (string-append root "/blueprint.scm")
                              host
                              (or (let ((hu (getenv "HOME_USER")))
                                    (and hu (not (string-null? hu)) hu))
                                  (user-profile-name %primary-user))))
                       (%postflight-drift root head-before))))))

;; 内部 privileged mode（Blue self-reexec 的 root phase）。
;; dot 前缀：blue help 默认过滤 dot command，不作为用户命令宣传；
;; 非 root 调用直接拒绝。
(define-command (reconfigure-root-command arguments)
                ((invoke ".reconfigure-root")
                 (category 'internal)
                 (synopsis "Internal privileged reconfigure transaction (root only)")
                 (help "HOST [HOME_USER]
Internal mode for blue reconfigure's sudo handoff. Requires effective
UID 0. Runs the (guixcfg system reconfigure) gate transaction and exits
with its exact status (0 success / 1 system failure / 2 post-system
failure)."))
                (unless (zero? (getuid))
                  (%usage-error
                   "privileged reconfigure mode requires root (effective UID 0)"))
                (match arguments
                       ((host home-user)
                        (primitive-exit
                         (reconfigure-transaction!
                          host
                          (if (string-null? home-user)
                            (user-profile-name %primary-user)
                            home-user))))
                       (_ (%usage-error
                           "usage (internal): HOST HOME_USER"))))

;;; ---------- update ----------

(define (%channel-commits text)
  "从 (list (channel ...) ...) 文本提取 ((name . commit) ...)。"
  (let ((form (call-with-input-string text read)))
    (map (lambda (decl)
           (let ((alist (channel-declaration-alist decl)))
             (cons (assq-ref alist 'name) (assq-ref alist 'commit))))
         (filter (lambda (x) (and (pair? x) (eq? (car x) 'channel)))
                 form))))

(define (%print-lock-summary old new)
  "按频道打印 old → new commit 摘要。"
  (let ((old-commits (%channel-commits old))
        (new-commits (%channel-commits new)))
    (for-each (lambda (new-entry)
                (let ((old-entry (assq (car new-entry) old-commits)))
                  (format #t "  ~a: ~a -> ~a~%"
                          (car new-entry)
                          (if old-entry (cdr old-entry) "<new>")
                          (cdr new-entry))))
              new-commits)))

(define-command (update-command arguments)
                ((invoke "update")
                 (category 'maintenance)
                 (synopsis "Rewrite channels.lock.scm from mutable channels.scm")
                 (help "Resolve mutable channels.scm and atomically rewrite
channels.lock.scm. Never builds, deploys, runs guix pull, or commits.
With blue -n: command preview only -- no network access, no lock
rewrite, no knowledge of future channel revisions."))
                (unless (null? arguments)
                  (error "blue update takes no arguments"))
                (let* ((root (%repo-root))
                       (lock (string-append root "/channels.lock.scm"))
                       (argv (channel-lock-refresh-argv root)))
                  (if (dry-build?)
                    (begin
                     (format #t "  [dry-run] ~{ ~a~}~%" argv)
                     (format #t "  target: ~a~%" lock))
                    (let ((old (call-with-input-file lock get-string-all)))
                      (call-with-values
                       (lambda () (%capture argv))
                       (lambda (content status)
                         (unless (zero? status)
                           (format (current-error-port)
                                   "channel refresh failed (exit ~a)~%" status)
                           (primitive-exit (or status 1)))
                         (atomic-write-file! lock
                                             (lambda (port) (display content port)))
                         (format #t "channels.lock.scm updated~%")
                         (%print-lock-summary old content)))))))

;;; ---------- flatpak（user application lifecycle） ----------

;; 域机制全部在 (guixcfg flatpak reconcile)/(model)；这里只做
;; action dispatch、dry-run 集成与错误传播（Blue owns invocation,
;; Flatpak module owns behavior）。action 契约（集合/参数形态）的
;; 单一事实源是 reconcile 的 %flatpak-actions /
;; flatpak-validate-action-arguments。

(define (%flatpak-usage-error)
  (format (current-error-port)
          "Usage: blue flatpak ACTION [ARGS...]~%actions: ~a~%"
          (string-join (flatpak-actions) ", "))
  (primitive-exit 1))

(define (%flatpak-print-lines lines)
  (for-each (lambda (line) (format #t "~a~%" line)) lines))

(define (%flatpak-command arguments)
  ;; 域函数抛错（drift / unknown name / unknown remote / flatpak
  ;; 缺失）统一转为单行打印 + exit 1——blue 的 backtrace 打印器对
  ;; 含多字节注释的源文件会 out-of-range 崩溃（见 %usage-error 注释）。
  (catch #t
    (lambda ()
      ;; flatpak 一切操作 --user scope：root 运行会把状态落到
      ;; /root/.local/share/flatpak（root 自己的 user installation），
      ;; 与真实用户状态完全平行、绝不正确，且"有输出"会诱导误判
      ;; 成功——直接拒绝。
      (when (zero? (getuid))
        (format (current-error-port)
                "flatpak: refusing to run as root (all operations are --user scope; root would act on /root/.local/share/flatpak, not your user installation).~%")
        (primitive-exit 1))
      ;; flatpak-binary 显式回退到 guix 标准安装位置（VM system
      ;; profile），并把其目录前置进 PATH：reconcile 全程用 PATH
      ;; 解析子进程（invoke "flatpak" …），ssh 非 login shell 的
      ;; PATH 没有 system profile，不补这里所有子调用都会找不到。
      (let ((binary (flatpak-binary)))
        (setenv "FLATPAK_BINARY" binary)
        (setenv "PATH" (string-append (dirname binary)
                                      ":"
                                      (or (getenv "PATH") ""))))
      (match (flatpak-validate-action-arguments
              (and (pair? arguments) (car arguments))
              (if (pair? arguments) (cdr arguments) '()))
             (#f (%flatpak-usage-error))
             ;; status 纯只读：dry-run 也真实执行（只读查询不拦截）。
             (('status ())
              (flatpak-status))
             (('status (refresh))
              (flatpak-status #:refresh? #t))
             ;; sync -n：真实只读 plan（remote/app diff），绝不修改。
             (('sync ())
              (if (dry-build?)
                (%flatpak-print-lines
                 (flatpak-sync-plan %flatpak-remotes
                                    %flatpak-applications
                                    %flatpak-selection))
                (flatpak-sync)))
             ;; update -n：真实只读 ref plan（不联网、不安装）。
             (('update ())
              (if (dry-build?)
                (let ((refs (flatpak-update-plan %flatpak-applications
                                                 %flatpak-selection)))
                  (if (null? refs)
                    (format #t "No unpinned selected applications to update.~%")
                    (%flatpak-print-lines
                     (map (cut format #f "would update ~a" <>) refs))))
                (flatpak-update)))
             (('update-runtimes ())
              (if (dry-build?)
                (let ((refs (flatpak-update-runtimes-plan)))
                  (if (null? refs)
                    (format #t "No installed runtimes to update.~%")
                    (%flatpak-print-lines
                     (map (cut format #f "would update runtime ~a" <>) refs))))
                (flatpak-update-runtimes)))
             ;; remove -n：目标预览（参数解析照常，未知 name 照常报错）。
             (('remove (name))
              (if (dry-build?)
                (let ((app (flatpak-remove-plan (string->symbol name)
                                                %flatpak-applications)))
                  (format #t "would uninstall ~a (user data under ~~/.var/app/~a preserved)~%"
                          (flatpak-application-id app)
                          (flatpak-application-id app)))
                (flatpak-remove (string->symbol name))))
             ;; remote-replace -n：当前/目标 remote 与将发生的操作预览。
             (('remote-replace (name))
              (let ((remote (flatpak-remote-by-name (string->symbol name))))
                (if (dry-build?)
                  (let ((current (flatpak-replace-remote-plan remote)))
                    (format #t "remote ~a: current url ~a~%"
                            name (or current "(not configured)"))
                    (format #t (if current
                                 "would explicitly delete the existing remote and rebuild it~%"
                                 "would add the remote (bootstrap + canonicalize)~%"))
                    (format #t "  descriptor: ~a~%  transport:  ~a~%"
                            (flatpak-remote-descriptor-url remote)
                            (flatpak-remote-repository-url remote)))
                  (flatpak-replace-remote! remote))))
             ;; gc -n：command preview only（pinned Flatpak 无 unused
             ;; runtime 只读枚举；不伪造删除列表）。
             (('gc ())
              (if (dry-build?)
                (begin
                 (format #t "gc preview (no read-only equivalent; commands that would run):~%")
                 (%flatpak-print-lines
                  (map (lambda (argv) (format #f "  ~{ ~a~}" argv))
                       (flatpak-gc-commands))))
                (flatpak-gc)))))
    (lambda (key . args)
      (format (current-error-port) "flatpak: ~a~%"
              (string-join (exception-strings args) " "))
      (primitive-exit 1))))

(define-command (flatpak-command arguments)
                ((invoke "flatpak")
                 (category 'applications)
                 (synopsis "Manage user Flatpak applications (declarative convergence)")
                 (help "ACTION [ARGS...]
User-scope Flatpak lifecycle (never system/sudo; never runs at
boot/reconfigure). Actions:
  sync                       ensure declared remotes + selected apps (add-only)
  status [--refresh]         show declared/installed state (offline;
                             --refresh queries remotes)
  update                     update unpinned selected+installed apps
  update-runtimes            update installed runtimes (explicit refs)
  remove <logical-name>      uninstall one catalog application (user data kept)
  remote-replace <name>      explicit source switch: delete + rebuild remote
  gc                         remove unused runtimes + repair installation
Dry-run (blue -n):
  status                     real read-only execution
  sync / update / update-runtimes
                             real read-only plan (no changes)
  remove / remote-replace    target preview (no changes; args validated)
  gc                         command preview only (no read-only equivalent)"))
                (%flatpak-command arguments))

;;; ============================================================
;;; §3.7 GSettings namespace（repository-derived static app
;;; preferences；docs/architecture/gsettings.md）
;;; ============================================================
;;; 域机制全部在 (guixcfg gsettings model)/(reconcile)/(serialize)，
;;; 执行入口在 tools/gsettings.scm（pinned 子进程）。blueprint 只做
;;; action 校验与调度（与 blue check → tests/run-tests.scm 同模式）。
;;;
;;; 为什么域执行必须进 pinned 子进程（决策记录，见
;;; tools/gsettings.scm 头部）：
;;;   1. desired state 事实源 apps registry 的 39 个 definition 中
;;;      8 个依赖 channel 模块、且引用的 guix 包必须来自 pinned
;;;      channels——`guix time-machine shell` 的 GUILE_LOAD_PATH 只
;;;      带宿主机 guix current（宿主机 guix 已把 fastfetch 改名
;;;      fastfetch-minimal，直接解析 registry 会 Unbound variable）；
;;;   2. blueprint 编译期导入非平凡新模块会在外层 link 阶段触发
;;;      guile out-of-range 崩溃（嵌套编译，实测）。
;;; 因此 action 校验经 runtime resolve-interface（标准 loader 编译
;;; 路径，与测试套件相同）；status/apply 一律 %exec 进 pinned repl。

(define (%gsettings-validation-runtime)
  ;; runtime 惰性解析（仅 action 集合/参数校验用；域执行在 pinned
  ;; 子进程，不在此处）。gsettings-actions 是过程（reconcile 导出
  ;; 签名），取回后调用得列表。
  (let ((reconcile (resolve-interface '(guixcfg gsettings reconcile))))
    (list ((module-ref reconcile 'gsettings-actions))
          (module-ref reconcile 'gsettings-validate-action-arguments))))

(define (%gsettings-script-argv action)
  "ACTION（status | apply | dry-run-apply）的 pinned 执行 argv。"
  `("guix" "time-machine" "-C"
           ,(string-append (%repo-root) "/channels.lock.scm")
           "--" "repl" ,(string-append (%repo-root) "/tools/gsettings.scm")
           "--" ,action))

(define (%gsettings-usage-error actions)
  (format (current-error-port)
          "Usage: blue gsettings ACTION~%actions: ~a~%"
          (string-join actions ", "))
  (primitive-exit 1))

(define (%gsettings-command arguments)
  (catch #t
    (lambda ()
      ;; root 拒绝（同 flatpak）：root 进程的 dconf 落在
      ;; /root/.config/dconf，是与真实用户完全平行的错误作用域。
      (when (zero? (getuid))
        (format (current-error-port)
                "gsettings: refusing to run as root (projection targets the user's runtime dconf; root would act on /root/.config/dconf, not your session).~%")
        (primitive-exit 1))
      (match (%gsettings-validation-runtime)
             ((actions validate)
              (match (validate
                      (and (pair? arguments) (car arguments))
                      (if (pair? arguments) (cdr arguments) '()))
                     (#f (%gsettings-usage-error actions))
                     ;; status 纯只读：dry-run 也真实执行（只读查询不拦截）。
                     ;; apply：-n 下脚本走 dry-run-apply（真实 status/diff +
                     ;; 零 mutation，绝不 invoke dconf load）；正常走 apply。
                     ;; 一律 %exec（真实执行），dry-run 语义由脚本模式承担。
                     (('status ())
                      (%exec (%gsettings-script-argv "status")))
                     (('apply ())
                      (%exec (%gsettings-script-argv
                              (if (dry-build?) "dry-run-apply" "apply"))))))))
    (lambda (key . args)
      (format (current-error-port) "gsettings: ~a~%"
              (string-join (exception-strings args) " "))
      (primitive-exit 1))))

(define-command (gsettings-command arguments)
                ((invoke "gsettings")
                 (category 'applications)
                 (synopsis "Inspect/apply repository-derived GSettings (runtime dconf projection)")
                 (help "ACTION
Repository-managed static application preferences (declarative
desired state → disposable runtime dconf; ~/.config/dconf is never
persisted, reboot is the reset boundary). Actions:
  status                     real read-only per-key desired/current diff
  apply                      validate → serialize → dconf load /
                             (writes only managed keys; never resets
                             unmanaged state)
Dry-run (blue -n):
  status                     real read-only execution
  apply                      real status/diff + plan, zero mutation
                             (never invokes dconf load)"))
                (%gsettings-command arguments))

;;; ============================================================
;;; §4 repository-tests testable（builtin blue check 的薄 adapter）
;;; ============================================================

;; 唯一测试事实源仍是 tests/run-tests.scm；此 testable 只做 adapter，
;; 不复制测试清单、不拆分测试。blue -n check 由 Blue 内建 dry-run
;; 语义短路（不真正运行测试套件——有意为之，见 docs/development/testing.md）。
(define-blue-class <repository-tests>
                   (inherit <testable>)
                   (constructor repository-tests)
                   (predicate repository-tests?))

(define (%repository-tests-command)
  (guix-time-machine-argv (%repo-root) "channels.lock.scm"
                          '("repl" "tests/run-tests.scm")))

(define-blue-method (ask-build-manifest (this <repository-tests>)
                                        (inputs <list>)
                                        (output <string>))
                    (make-build-manifest
                     "REPOSITORY TESTS"
                     (lambda ()
                       (%run (%repository-tests-command)
                             #:working-directory (%repo-root))
                       (mkdir-p (dirname output))
                       (call-with-output-file output
                                              (lambda (port) (display "ok\n" port))))))

(define %repository-tests
  (repository-tests
   (inputs '())
   (outputs '(".blue-store/check/repository-tests.marker"))))

;;; ============================================================
;;; §5 入口
;;; ============================================================

(blueprint
 (testables (list %repository-tests))
 (commands (list doctor-command
                 build-os-command
                 reconfigure-command
                 reconfigure-root-command
                 update-command
                 flatpak-command
                 gsettings-command)))
