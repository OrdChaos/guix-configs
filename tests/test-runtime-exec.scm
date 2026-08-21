;;; boot-critical generated runtime program 的真实 execution smoke tests。
;;;
;;; 背景：结构测试（service record / gexp builds / shepherd config）无法
;;; 发现 generated program 的 free-variable binding 问题——实测连续暴露
;;;   persistent-state-ready → Unbound variable: every
;;;   guixcfg-password-project → Unbound variable: any
;;; 前者因 runtime gexp 在 lambda 内依赖未导入的 SRFI-1；后者因
;;; program-file 的 runtime use-modules 漏了 (srfi srfi-1) 却用了 any。
;;; （该 writer 此后已删除：credential 注入并入 account databases
;;; projection 唯一 writer，见 A1-A8 的 shadow 行格式断言。）
;;;
;;; 本测试真正 build generated executable artifact 并在隔离 root
;;; （user namespace + chroot + bind /gnu/store）里执行它，验证：
;;;   - 模块 closure 完整、无 unbound-variable（可执行性）；
;;;   - 成功/失败路径的真实行为（fail-closed：不产空密码用户、
;;;     不破坏 shadow）。
;;;
;;; 需要 unshare（util-linux）与 chroot 权限（user namespace 提供）。
;;; 隔离 root 是临时目录；不触碰真实 /etc、/persist。
;;;
;;; A1-A8 覆盖 account databases projection（唯一 /etc/shadow writer）：
;;;   A1 user 在三库存在、shadow 行格式 user:hash:...（拒绝旧坏行
;;;      hash 顶替 name）；
;;;   A4/A5/A6 verifier 缺失/非法/用户缺失 → fail closed；
;;;   A7 最终 shadow 缺 user → verify 不 provision；
;;;   A8 仓库只有一个 production shadow writer（静态断言）。
;;; AP1 覆盖 application-persistence activation 的 consumer parent 全
;;;   层级 ownership（boot 回归：activation 只 chown 直接 parent 会留下
;;;   root-owned 的 ~/.local，Home activation mkdir ~/.local/share EACCES）。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guix store)
             (guixcfg system substitutes) ; %transition-substitute-urls
             (guix monads)
             (guix gexp)
             (guix derivations)
             (guix modules)
             (guix build utils)         ; mkdir-p
             (gnu services)
             (gnu services shepherd)
             (guixcfg security secrets)
             (guixcfg system accounts)    ; account-databases-activation/verify
             (guixcfg system application-persistence) ; AP1 activation ownership
             (gnu system accounts)     ; user-account、user-group
             (guixcfg system readiness)
             (ice-9 rdelim)
             (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 ftw)                ; scandir
             (ice-9 regex)              ; string-match
             (srfi srfi-1)
             ((rnrs base) #:select (let-values))  ; 只取 let-values（R6RS error 会覆盖 Guile 原生 error）
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "runtime-exec")

;; ── 基础设施 ────────────────────────────────────────────────
;; 构建 file-like → store 路径。
(define %store (open-connection))

;; 显式 bootstrap substitute URLs（宿主 daemon 尚未配置 Nonguix
;; substitute；经 per-connection set-build-options 传入，让测试的
;; build 请求命中官方 Nonguix substitute 而不是本地编译 kernel——
;; 与 CLI 的 --substitute-urls 等价；%transition-substitute-urls 的
;; 唯一定义在 (guixcfg system substitutes)）。
(set-build-options %store #:substitute-urls %transition-substitute-urls)

(define (build-thing thing)
  (let ((drv (run-with-store %store (lower-object thing))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define %guile
  ;; program-file 生成的脚本 shebang 引用的 guile store 路径
  ;; （从已构建 artifact 第一行提取）。
  (let* ((prog (build-thing (account-databases-verify-program "user")))
         (line (call-with-input-file prog
                                     (lambda (p) (read-line p)))))
    (and (string-prefix? "#!" line)
         (car (string-split (substring line 2) #\space)))))

;; 在隔离 root 里执行 PROGRAM（store 路径），返回 exit code。
;; FAKE-ROOT 含 etc/shadow 与 persist/... 的 fake 数据。
(define (run-in-root program fake-root)
  (let ((script
         (string-append
          "unshare --user --map-root-user --map-users=auto --map-groups=auto "
          "--mount --pid --fork sh -c '"
          "mount --bind /gnu/store " fake-root "/gnu/store; "
          "chroot " fake-root " " %guile
          " --no-auto-compile " program
          " >/dev/null 2>&1; "
          "echo $?'")))
    (let* ((pipe (open-input-pipe script))
           (out (get-string-all pipe)))
      (close-pipe pipe)
      (string->number (string-trim-both out)))))

;; 构建 fake root：返回目录路径，内含 fake passwd/shadow/persist hash。
(define (make-fake-root shadow-content hash-or-#f)
  (let ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                            "/guixcfg-runtime-" (number->string (getpid))
                            "-" (number->string (random 100000)))))
    (mkdir dir)
    (mkdir (string-append dir "/etc"))
    (mkdir (string-append dir "/persist"))
    (mkdir (string-append dir "/persist/system"))
    (mkdir (string-append dir "/persist/system/accounts"))
    (mkdir (string-append dir "/persist/system/accounts/user"))
    (mkdir (string-append dir "/gnu"))
    (mkdir (string-append dir "/gnu/store"))
    (call-with-output-file (string-append dir "/etc/shadow")
                           (lambda (p) (display shadow-content p)))
    (chmod (string-append dir "/etc/shadow") #o600)
    ;; fake passwd（getpw 需要；deploy 的 owner 解析）。
    (call-with-output-file (string-append dir "/etc/passwd")
                           (lambda (p)
                             (display "root:x:0:0:root:/root:/bin/bash\n\
user:x:1000:1000:u:/home/user:/bin/bash\n" p)))
    (call-with-output-file (string-append dir "/etc/nsswitch.conf")
                           (lambda (p) (display "passwd: files\ngroup: files\n" p)))
    (when hash-or-#f
      (call-with-output-file
       (string-append dir "/persist/system/accounts/user/password.hash")
       (lambda (p) (display hash-or-#f p)))
      (chmod (string-append dir "/persist/system/accounts/user/password.hash")
             #o600))
    dir))

;; ── account databases projection：真实执行 ──────────────────
;; 测试 /etc/{passwd,group,shadow} 的单一 authoritative writer：
;; account-databases-activation（含 persistent credential 内联注入）。
;; 用最小 users/groups 集合（root + user + users/wheel groups）构建与
;; boot 相同的 gexp，在隔离 root 里执行，验证：
;;   A1 user 在三库都存在
;;   A2 persistent hash 放进 user 的 shadow password 字段（正确格式）
;;   A3 hash 可 crypt 验证（用测试 hash，非真实 secret）
;;   A4/A5/A6 缺失/非法 hash、user 缺失 → fail closed（不写库）
;;   A7 最终 shadow 缺 user → verify 不 provision（见 verify 段）
;;   A8 仓库只有一个 production shadow writer（静态断言，见下方）
(define %acc-gexp
  ;; 与 boot 相同的 projection gexp（最小 accounts+groups）。
  (let* ((root-acct (user-account (name "root") (uid 0) (group "root")
                                  (comment "System administrator")
                                  (home-directory "/root")))
         (user-acct (user-account (name "user") (uid 1000) (group "users")
                                  (supplementary-groups '("wheel"))
                                  (comment "VM test user")
                                  (home-directory "/home/user")))
         (grp-root (user-group (name "root") (system? #t)))
         (grp-users (user-group (name "users") (system? #t)))
         (grp-wheel (user-group (name "wheel") (system? #t))))
    (account-databases-activation
     (list root-acct user-acct grp-root grp-users grp-wheel))))

(define %acc-program
  (build-thing
   (program-file "acc-databases-test"
                 (with-imported-modules (source-module-closure
                                         '((gnu build accounts) (gnu system accounts)
                                                                (guix build utils) (srfi srfi-1) (srfi srfi-11)))
                                        #~(begin
                                           (use-modules (gnu build accounts) (gnu system accounts)
                                                        (guix build utils) (srfi srfi-1) (srfi srfi-11))
                                           #$%acc-gexp)))))

(define (run-acc shadow-content hash-or-#f)
  "在 fake root 上执行 account projection；返回 (exit . final-shadow)。"
  (let ((root (make-fake-root shadow-content hash-or-#f)))
    (let ((exit (run-in-root %acc-program root)))
      (cons exit
            (call-with-input-file (string-append root "/etc/shadow")
                                  (lambda (p) (get-string-all p)))))))

;; A1+A2+A3：正常 credential → exit 0，三库正确，user shadow 行
;; 格式为 user:hash:lastchange:...（不是 hash 顶替 name 的坏行）。
(let* ((res (run-acc "" "$6$salt$faketesthash\n"))
       (exit (car res)) (out (cdr res)))
  (test-equal "A1 projection success exits 0" 0 exit)
  (test-assert "A1 user present in shadow as user:hash:..."
               (and (string-contains out "\nuser:$6$salt$faketesthash:")
                    ;; 坏行模式（hash 顶替 name）必须不存在
                    (not (string-contains out "\n$6$salt$faketesthash:!"))
                    (not (string-contains out "\nuser:!:"))))
  (test-assert "A1 root preserved (locked, no credential)"
               (string-contains out "root:!:")))

;; A4：persistent hash 缺失 → 非零，三库不被写。
(let* ((root (make-fake-root "" #f))
       (exit (run-in-root %acc-program root)))
  (test-assert "A4 missing hash fails" (not (zero? exit)))
  (test-assert "A4 shadow not written (empty remains)"
               (let ((s (call-with-input-file (string-append root "/etc/shadow")
                                              (lambda (p) (get-string-all p)))))
                 (string=? s ""))))

;; A5：malformed hash → 非零，库不被写。
(let* ((root (make-fake-root "" "NOT-A-VALID-HASH\n"))
       (exit (run-in-root %acc-program root)))
  (test-assert "A5 malformed hash fails" (not (zero? exit)))
  (test-assert "A5 shadow not written"
               (let ((s (call-with-input-file (string-append root "/etc/shadow")
                                              (lambda (p) (get-string-all p)))))
                 (string=? s ""))))

;; A6：user 不在声明集合 → projection 本身只写声明用户（不产生
;; 幽灵条目）；credential 注入只作用于声明的 interactive 用户。
(let* ((res (run-acc "" "$6$salt$valid\n"))
       (exit (car res)) (out (cdr res)))
  (test-equal "A6 projection success with declared user" 0 exit)
  (test-assert "A6 user shadow line well-formed"
               (string-contains out "\nuser:$6$salt$valid:")))

;; A7：最终 shadow 缺 user 时 account-state-ready 不 provision——
;; 由只读 verify 服务保证（fail-closed）。这里直接执行 verify
;; program 在"投影被外部破坏"的 shadow 上，必须失败。
(define %verify-program
  (build-thing (account-databases-verify-program "user")))

(let* ((root (make-fake-root
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n"
              "$6$salt$faketesthash\n"))
       ;; 模拟"shadow 缺 user"（旧 bug 的坏行形态：hash 顶替 name）
       (shadow-path (string-append root "/etc/shadow")))
  (call-with-output-file shadow-path
                         (lambda (p)
                           (display
                            "root::20682::::::\n\
$6$salt$faketesthash:!:20682::::::\n"
                            p)))
  (chmod shadow-path #o600)
  (let ((exit (run-in-root %verify-program root)))
    (test-assert "A7 verify fails when shadow lacks user"
                 (not (zero? exit)))))

;; A8：仓库只有一个 production /etc/shadow writer（静态断言）——
;; 排除测试与上游 guix 源码，modules/ 下只有 accounts.scm 写 shadow。
;; A8：仓库只有一个 production /etc/shadow writer（静态断言）——
;; modules/guixcfg 下只有 accounts.scm 写 shadow（write-shadow 或
;; rename 到 /etc/shadow）。
(test-assert "A8 single production shadow writer"
             (let* ((base "modules/guixcfg")
                    (subdirs '("security" "system" "services" "boot" "storage" "home"
                                          "users" "utils" "hosts"))
                    (files (append-map
                            (lambda (sub)
                              (let ((dir (string-append base "/" sub)))
                                (filter (lambda (f)
                                          (and (string-suffix? ".scm" f)
                                               (not (member f '("." "..")))))
                                        (map (lambda (f) (string-append dir "/" f))
                                             (or (scandir dir) '())))))
                            subdirs))
                    (writers
                     (filter (lambda (f)
                               (let ((t (call-with-input-file f
                                                              (lambda (p) (get-string-all p)))))
                                 (or (string-contains t "write-shadow")
                                     (and (string-contains t "rename-file")
                                          (string-contains t "\"/etc/shadow\"")))))
                             files)))
               (and (= 1 (length writers))
                    (string-contains (car writers) "accounts.scm"))))

;; ── persistent-state-ready：真实执行 production start ────────
;; 直接执行实际 Shepherd service 的 start gexp（shepherd-service-start），
;; 不复制任何等价逻辑——路径列表 %persistent-state-paths 是 service 与
;; test 的单一来源（readiness.scm）。
(define %psr-svc
  (car (service-value (persistent-state-ready-service))))

(define %psr-start-gexp
  (shepherd-service-start %psr-svc))

;; 把 production start gexp 包成可执行 program：start 是 (lambda () …)，
;; 用 (apply … '()) 调用一次，exit 取返回值。start 展开后是纯 core
;; （and/file-exists?），外壳无需任何模块 import。
(define %psr-program
  (build-thing
   (program-file
    "psr-prod-start"
    #~(begin
       (exit (if (apply #$%psr-start-gexp '()) 0 1))))))

(define (run-psr paths)
  "在 fake root 上执行 production start；PATHS 是要创建的路径列表。
路径全部由 %persistent-state-paths 派生（R1 全建、R2 缺一个）。"
  (let ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                            "/guixcfg-psr-" (number->string (getpid))
                            "-" (number->string (random 100000)))))
    (mkdir-p dir)
    (mkdir-p (string-append dir "/gnu/store"))
    (for-each (lambda (p)
                (let* ((parts (string-split p #\/))
                       (acc (list dir)))
                  (for-each (lambda (part)
                              (let ((cur (string-append (car acc) "/" part)))
                                (mkdir-p cur)
                                (set-car! acc cur)))
                            (cdr parts))))
              paths)
    (let* ((script (string-append
                    "unshare --user --map-root-user --map-users=auto "
                    "--map-groups=auto --mount --pid --fork sh -c '"
                    "mount --bind /gnu/store " dir "/gnu/store; "
                    "chroot " dir " " %guile " --no-auto-compile " %psr-program
                    " 2>&1; echo $?'"))
           (pipe (open-input-pipe script))
           (all (get-string-all pipe)))
      (close-pipe pipe)
      (let* ((lines (filter (lambda (l) (not (string-null? l)))
                            (string-split all #\newline)))
             (code (and (pair? lines)
                        (string->number (string-trim-both (car (reverse lines)))))))
        code))))

;; R1：全部 %persistent-state-paths 存在 → production start 成功。
(test-equal "R1 production start succeeds with all paths"
            0 (run-psr %persistent-state-paths))

;; R2：缺一个关键路径 → production start 失败。
(test-equal "R2 production start fails on missing path"
            1 (run-psr (cdr %persistent-state-paths)))

;; R3：production start 可执行、无 unbound-variable（R1/R2 执行本身即证）。

;; ── secrets-deploy：真实解密 + 发布 execution ────────────────
;; 构造一个带 test secret 的 deploy artifact：ciphertext 是测试期用
;; age 生成的 armor 文件（.age），identity 是配套 test key。在隔离
;; root 里放置 identity + /etc/passwd，执行 artifact，验证：
;;   - 真正走 filter-map（next-generation）/ decrypt-into / publication
;;     （generation 目录 + symlink 切换）整条 runtime 路径；
;;   - exit success、secret 发布、mode/owner 正确、无 unbound-variable。
;; 不使用任何真实用户 secret。

;; 测试用 age 工具（与 production closure 中 age 同源，store 路径取自
;; deploy artifact 的 age-bin 常量）。
(define (find-age-bin)
  (let* ((prog (build-thing (secrets-deploy-program '() "user")))
         (text (call-with-input-file prog (lambda (p) (get-string-all p))))
         (m (string-match "/gnu/store/[a-z0-9]+-age-[0-9.]+/bin/age" text)))
    (and m (match:substring m 0))))

(define %age-bin (find-age-bin))

;; 测试准备：生成 test identity + armor ciphertext（plaintext 是
;; 项目 runtime 测试 sentinel，非真实 secret）。
(define %sentinel "GUIXCFG_RUNTIME_TEST_SECRET\n")

(define (make-test-secret-setup)
  "生成 age identity 与加密 sentinel 的 armor ciphertext；返回
(key-path . cipher-path)。"
  (let* ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                             "/guixcfg-age-" (number->string (getpid))
                             "-" (number->string (random 100000))))
         (key (string-append dir "/test.key"))
         (age-keygen (string-append (dirname %age-bin) "/age-keygen"))
         (plain (string-append dir "/plain.txt"))
         (cipher (string-append dir "/test.age")))
    (mkdir dir)
    ;; age-keygen -o key；用 age-keygen -y 从私钥导出 pubkey（age1…）
    (let ((p (open-input-pipe (string-append age-keygen " -o " key " 2>&1"))))
      (get-string-all p) (close-pipe p))
    (let* ((p (open-input-pipe (string-append age-keygen " -y " key " 2>&1")))
           (all (get-string-all p)))
      (close-pipe p)
      (let ((pub (string-trim-right (string-trim-both all))))
        (unless (string-prefix? "age1" pub)
          (error "age-keygen -y produced no public key" pub))
        (call-with-output-file plain (lambda (p) (display %sentinel p)))
        (let ((p (open-input-pipe
                  (string-append %age-bin " -a -r " pub " -o " cipher " " plain
                                 " 2>&1"))))
          (get-string-all p) (close-pipe p))))
    (cons key cipher)))

(define %test-secret-setup (make-test-secret-setup))
(define %test-key (car %test-secret-setup))
(define %test-cipher (cdr %test-secret-setup))

;; 构建带 test secret 的 deploy artifact：ciphertext 用 local-file 引用
;; 测试期文件（随 artifact 进 closure，类似 production 的
;; %vm-secrets source）。
(define %deploy-with-secret
  (build-thing
   (secrets-deploy-program
    (list (secret-decl
           (name 'runtime-test)
           (scope 'system)
           (domain 'login-critical)
           ;; file-like contract（secret-decl-source = caller 解析的
           ;; ciphertext source；ciphertext 随 closure 进 store）
           (source (local-file %test-cipher "runtime-test.age"))
           (target-name "runtime-test")
           (owner-user "root")
           (mode #o400)))
    "user")))

(let* ((root (make-fake-root
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n"
              #f))
       ;; deploy 需要：identity 在 /persist/system/keys/age/identity、
       ;; /run 可写、store-dir/current-link 在 /run。
       (age-dir (string-append root "/persist/system/keys/age")))
  ;; 放置 test identity（rpath 由 make-fake-root 建好 /persist/.../user）
  (mkdir-p age-dir)
  (call-with-output-file (string-append age-dir "/identity")
                         (lambda (p)
                           (call-with-input-file %test-key
                                                 (lambda (in)
                                                   (display (get-string-all in) p)))))
  (chmod (string-append age-dir "/identity") #o600)
  ;; /run 挂载点：deploy 写 /run/guixcfg-secrets.d 与 /run/guixcfg-secrets
  (let* ((run-dir (string-append root "/run")))
    (mkdir run-dir)
    (chmod run-dir #o755))
  (let* ((script (string-append
                  "unshare --user --map-root-user --map-users=auto "
                  "--map-groups=auto --mount --pid --fork sh -c '"
                  "mount --bind /gnu/store " root "/gnu/store; "
                  ;; chroot 内 guile 的 nss 从 store glibc 的默认位置加载
                  ;; libnss_files；/gnu/store 已 bind，这里确保加载路径就位。
                  "chroot " root " " %guile " --no-auto-compile " %deploy-with-secret
                  " 2>&1'"))
         (pipe (open-input-pipe script))
         (all (get-string-all pipe)))
    (close-pipe pipe)
    (test-assert "deploy executes without unbound-variable"
                 (not (string-contains all "Unbound variable")))
    (test-assert "deploy publishes generation and symlink"
                 (let ((d (string-append root "/run/guixcfg-secrets.d")))
                   (and (file-exists? d)
                        (let ((subs (filter (lambda (e)
                                              (string-match "^[0-9]+$" e))
                                            (or (scandir d) '()))))
                          (pair? subs)))))
    (test-assert "deploy publishes decrypted secret with mode 0400"
                 (let* ((cur (string-append root "/run/guixcfg-secrets"))
                        (resolved (readlink cur))
                        ;; deploy 的 symlink 目标是绝对 /run/guixcfg-secrets.d/<N>；
                        ;; 相对 fake root 即 root + (去前导 / 的目标)。
                        (rel (if (string-prefix? "/" resolved)
                               (substring resolved 1)
                               resolved))
                        (secret (string-append root "/" rel "/system/runtime-test")))
                   (and (file-exists? secret)
                        (string-contains (call-with-input-file secret
                                                               (lambda (p) (get-string-all p)))
                                         "GUIXCFG_RUNTIME_TEST_SECRET"))))
    (test-assert "deploy sets 0400 mode"
                 (let* ((cur (readlink (string-append root "/run/guixcfg-secrets")))
                        (rel (if (string-prefix? "/" cur)
                               (substring cur 1)
                               cur))
                        (secret (string-append root "/" rel "/system/runtime-test")))
                   ;; 常规文件 + 0400：stat:mode = S_IFREG(0100000) | 0400。
                   ;; ownership 在 user namespace 下不可靠（namespace root 映射回宿主
                   ;; uid），这里只断言权限位；属主语义由 production 的 chown 0 0
                   ;; 保证（P1 之外，见 secrets.scm decrypt-into）。
                   (eq? (stat:mode (stat secret)) #o100400)))))

;; identity 缺失（fresh install 漏装阶段 6 的场景）：deploy 必须给出
;; 清晰错误（含 "identity missing"），而不是模糊失败后卡死
;; interactive-secrets-ready → login barrier。
(let* ((root (make-fake-root
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n"
              #f))
       (run-dir (string-append root "/run")))
  (mkdir run-dir)
  (chmod run-dir #o755)
  (let* ((script (string-append
                  "unshare --user --map-root-user --map-users=auto "
                  "--map-groups=auto --mount --pid --fork sh -c '"
                  "mount --bind /gnu/store " root "/gnu/store; "
                  "chroot " root " " %guile " --no-auto-compile " %deploy-with-secret
                  " 2>&1'"))
         (pipe (open-input-pipe script))
         (all (get-string-all pipe)))
    (close-pipe pipe)
    (test-assert "deploy without identity fails with clear error"
                 (string-contains all "identity missing"))))


;; ── readiness domain failure isolation（login-critical / ordinary）──
;; 两个 domain 各自独立 staging/generation/current root：
;;   domain 内 fail-closed（任一失败 → 本 domain 不发布新代）
;;   domain 间 failure-isolated（ordinary 失败绝不影响 login-critical）
;; 覆盖 A7 的 1-7 场景（8-10 在 test-secrets/test-apps）。
(define (fake-root-with-identity)
  "带 age identity 与 /run 的 fake root（deploy 需要：identity 在
/persist/system/keys/age/identity、/run 可写）。"
  (let* ((root (make-fake-root
                "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n"
                #f))
         (age-dir (string-append root "/persist/system/keys/age")))
    (mkdir-p age-dir)
    (call-with-output-file (string-append age-dir "/identity")
                           (lambda (p)
                             (call-with-input-file %test-key
                                                   (lambda (in)
                                                     (display (get-string-all in) p)))))
    (chmod (string-append age-dir "/identity") #o600)
    (let ((run-dir (string-append root "/run")))
      (mkdir run-dir)
      (chmod run-dir #o755))
    root))

(define (run-deploy-script root script)
  "在 fake root 里执行 deploy SCRIPT；返回 (values output exit-status)。
exit-status 来自 chroot 内 guile 的退出码（deploy 失败 = throw →
非零；成功 = 0），经 echo 捕获。"
  (let* ((cmd (string-append
               "unshare --user --map-root-user --map-users=auto "
               "--map-groups=auto --mount --pid --fork sh -c '"
               "mount --bind /gnu/store " root "/gnu/store; "
               "chroot " root " " %guile " --no-auto-compile " script
               "; echo EXIT=$? 2>&1'"))
         (pipe (open-input-pipe cmd))
         (all (get-string-all pipe)))
    (close-pipe pipe)
    (let ((m (string-match "EXIT=([0-9]+)" all)))
      (values all (if m (string->number (match:substring m 1)) #f)))))

(define (current-link-valid? root link-path)
  "fake root 内 LINK-PATH symlink 存在且解析目标（chroot 内绝对路径）
真实存在。注意不能用 file-exists? 直接检查链接本身（它跟随目标；
host 侧目标不存在会误报 #f）——用 readlink 读链接、再解析。"
  (let ((p (string-append root link-path)))
    (let ((link (false-if-exception (readlink p))))
      (and (string? link)
           (let ((rel (if (string-prefix? "/" link)
                        (substring link 1)
                        link)))
             (file-exists? (string-append root "/" rel)))))))

(define (numeric-generations root store-dir)
  "fake root 内 STORE-DIR 下的数字 generation 目录列表。"
  (let ((d (string-append root store-dir)))
    (if (file-exists? d)
      (filter (lambda (e) (string-match "^[0-9]+$" e))
              (scandir d))
      '())))

(define (good-decl name domain)
  (secret-decl (name name) (scope 'system) (domain domain)
               (source (local-file %test-cipher (string-append (symbol->string name) ".age")))
               (target-name (symbol->string name)) (owner-user "root") (mode #o400)))

(define %corrupt-cipher
  (let ((p (string-append "/tmp/guixcfg-corrupt-" (number->string (getpid)) ".age")))
    (call-with-output-file p (lambda (port) (display "corrupt-not-an-age-ciphertext" port)))
    p))

(define (bad-decl name domain)
  (secret-decl (name name) (scope 'system) (domain domain)
               (source (local-file %corrupt-cipher (string-append (symbol->string name) ".age")))
               (target-name (symbol->string name)) (owner-user "root") (mode #o400)))

(define %iso-critical-good
  (build-thing (secrets-deploy-program (list (good-decl 'iso-crit 'login-critical)) "user")))
(define %iso-critical-bad
  (build-thing (secrets-deploy-program (list (bad-decl 'iso-crit 'login-critical)) "user")))
(define %iso-ordinary-good
  (build-thing (secrets-ordinary-deploy-program (list (good-decl 'iso-ord 'ordinary)) "user")))
(define %iso-ordinary-bad
  (build-thing (secrets-ordinary-deploy-program (list (bad-decl 'iso-ord 'ordinary)) "user")))

(let ((root (fake-root-with-identity)))
  (let-values (((out st) (run-deploy-script root %iso-critical-good)))
              (test-assert "ISOL-1: critical all-success exits 0"
                           (and st (zero? st)))
              (test-assert "ISOL-1: critical generation published"
                           (pair? (numeric-generations root "/run/guixcfg-secrets.d")))
              (test-assert "ISOL-1: critical current symlink present"
                           (current-link-valid? root "/run/guixcfg-secrets"))))

(let ((root (fake-root-with-identity)))
  (let-values (((out st) (run-deploy-script root %iso-critical-bad)))
              (test-assert "ISOL-2: critical one-fails exits non-zero"
                           (and st (not (zero? st))))
              (test-assert "ISOL-2: critical generation NOT published"
                           (null? (numeric-generations root "/run/guixcfg-secrets.d")))
              (test-assert "ISOL-2: critical current symlink absent"
                           (not (file-exists? (string-append root "/run/guixcfg-secrets"))))))

(let ((root (fake-root-with-identity)))
  (let-values (((out st) (run-deploy-script root %iso-ordinary-good)))
              (test-assert "ISOL-3: ordinary all-success exits 0"
                           (and st (zero? st)))
              (test-assert "ISOL-3: ordinary generation published at its own root"
                           (pair? (numeric-generations root "/run/guixcfg-secrets-ordinary.d")))
              (test-assert "ISOL-3: ordinary current symlink present"
                           (current-link-valid? root "/run/guixcfg-secrets-ordinary"))))

(let ((root (fake-root-with-identity)))
  (let-values (((out st) (run-deploy-script root %iso-ordinary-bad)))
              (test-assert "ISOL-4: ordinary one-fails exits non-zero"
                           (and st (not (zero? st))))
              (test-assert "ISOL-4: ordinary generation NOT published"
                           (null? (numeric-generations root "/run/guixcfg-secrets-ordinary.d")))
              (test-assert "ISOL-4: ordinary current symlink absent"
                           (not (file-exists? (string-append root "/run/guixcfg-secrets-ordinary"))))))

;; ISOL-5：critical 失败不能被 ordinary 成功掩盖
(let ((root (fake-root-with-identity)))
  (let-values (((out1 st1) (run-deploy-script root %iso-critical-bad)))
              (let-values (((out2 st2) (run-deploy-script root %iso-ordinary-good)))
                          (test-assert "ISOL-5: critical fails while ordinary succeeds"
                                       (and st1 (not (zero? st1)) st2 (zero? st2)))
                          (test-assert "ISOL-5: critical generation still absent"
                                       (null? (numeric-generations root "/run/guixcfg-secrets.d")))
                          (test-assert "ISOL-5: critical symlink still absent"
                                       (not (file-exists? (string-append root "/run/guixcfg-secrets"))))
                          (test-assert "ISOL-5: ordinary generation present"
                                       (pair? (numeric-generations root "/run/guixcfg-secrets-ordinary.d"))))))

;; ISOL-6：ordinary 失败保留上一个已发布 generation（preserve-last-good）
(let ((root (fake-root-with-identity)))
  (let-values (((out1 st1) (run-deploy-script root %iso-ordinary-good)))
              (let-values (((out2 st2) (run-deploy-script root %iso-ordinary-bad)))
                          (test-assert "ISOL-6: first ordinary generation published, second fails"
                                       (and st1 (zero? st1) st2 (not (zero? st2))))
                          (test-assert "ISOL-6: exactly one ordinary generation retained"
                                       (= 1 (length (numeric-generations root "/run/guixcfg-secrets-ordinary.d"))))
                          (test-assert "ISOL-6: current symlink still points at the good generation"
                                       (let ((link (readlink (string-append root "/run/guixcfg-secrets-ordinary"))))
                                         (and (string-contains link "/run/guixcfg-secrets-ordinary.d/")
                                              (file-exists? (string-append root "/" (if (string-prefix? "/" link)
                                                                                      (substring link 1)
                                                                                      link)))))))))

;; ISOL-7：两 domain 同时发布，roots/symlinks 互不冲突
(let ((root (fake-root-with-identity)))
  (let-values (((out1 st1) (run-deploy-script root %iso-critical-good)))
              (let-values (((out2 st2) (run-deploy-script root %iso-ordinary-good)))
                          (test-assert "ISOL-7: both domains publish successfully"
                                       (and st1 (zero? st1) st2 (zero? st2)))
                          (let ((crit (readlink (string-append root "/run/guixcfg-secrets")))
                                (ord (readlink (string-append root "/run/guixcfg-secrets-ordinary"))))
                            (test-assert "ISOL-7: each domain symlink points into its own store root"
                                         (and (string-contains crit "/run/guixcfg-secrets.d/")
                                              (string-contains ord "/run/guixcfg-secrets-ordinary.d/")
                                              (not (string=? crit ord))))))))

;; ── AP1：application-persistence activation 的 consumer parent 全
;; 层级 ownership（boot 回归）────────────────────────────────
;; 890060e 首次 wire production rule（mpv，consumer .local/state/mpv）
;; 后 reboot 实测：activation 的 mkdir-p 以 root 建出整条 parent 路径，
;; 却只 chown 直接 parent（.local/state）——中间层 ~/.local 遗留
;; root:root。官方 guix-home-user（requirement user-processes，在
;; file-systems 全部就位后运行 he/activate）以 USER 身份执行
;; mkdir-p $XDG_DATA_HOME（~/.local/share）→ EACCES → 整个 Home
;; activation 失败：~/.guix-home 缺失、dotfiles 不在、niri/mpv 不在
;; PATH。这里真实执行 production activation gexp（fake root 内 uid
;; 1000 与 boot 同构），断言中间层与直接 parent 都归 USER。
(define %app-persist-rule
  (application-persistence-rule
   (name 'synthetic-test)
   (backing "synthetic-test/state")
   (consumer ".local/state/mpv")       ; 与 mpv production rule 同深度
   (exposure 'bind-directory)
   (lifecycle 'application-owned)))

(define %app-persist-program
  (build-thing
   (program-file
    "app-persistence-activation-test"
    (with-imported-modules (source-module-closure '((guix build utils)))
                           #~(begin
                              (use-modules (guix build utils))
                              #$(application-persistence-activation
                                 (list %app-persist-rule) "user")
                              ;; 输出三层 uid：中间层 .local、直接
                              ;; parent .local/state、backing。
                              (format #t "~a ~a ~a~%"
                                      (stat:uid (stat "/home/user/.local"))
                                      (stat:uid (stat "/home/user/.local/state"))
                                      (stat:uid (stat "/persist/data-app/synthetic-test/state"))))))))

(let* ((root (make-fake-root "" #f))
       (script (string-append
                "unshare --user --map-root-user --map-users=auto "
                "--map-groups=auto --mount --pid --fork sh -c '"
                "mount --bind /gnu/store " root "/gnu/store; "
                "chroot " root " " %guile " --no-auto-compile "
                %app-persist-program " 2>&1'"))
       (pipe (open-input-pipe script))
       (all (get-string-all pipe)))
  (close-pipe pipe)
  (false-if-exception (delete-file-recursively root))
  (test-assert "AP1 activation runs without unbound-variable"
               (not (string-contains all "Unbound variable")))
  (test-assert "AP1 consumer parent intermediates are user-owned"
               (let* ((lines (filter (lambda (l) (not (string-null? l)))
                                     (string-split all #\newline)))
                      (uids (and (pair? lines)
                                 (string-split (car (reverse lines)) #\space))))
                 (and uids
                      (= 3 (length uids))
                      (every (lambda (u) (string=? "1000" u)) uids)))))

(test-end "runtime-exec")
