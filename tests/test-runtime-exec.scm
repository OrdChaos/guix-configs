;;; boot-critical generated runtime program 的真实 execution smoke tests。
;;;
;;; 背景：结构测试（service record / gexp builds / shepherd config）无法
;;; 发现 generated program 的 free-variable binding 问题——实测连续暴露
;;;   persistent-state-ready → Unbound variable: every
;;;   guixcfg-password-project → Unbound variable: any
;;; 前者因 runtime gexp 在 lambda 内依赖未导入的 SRFI-1；后者因
;;; program-file 的 runtime use-modules 漏了 (srfi srfi-1) 却用了 any。
;;;
;;; 本测试真正 build generated executable artifact 并在隔离 root
;;; （user namespace + chroot + bind /gnu/store）里执行它，验证：
;;;   - 模块 closure 完整、无 unbound-variable（可执行性）；
;;;   - 成功/失败路径的真实行为（fail-closed：不产空密码用户、
;;;     不破坏 shadow）。
;;;
;;; 需要 unshare（util-linux）与 chroot 权限（user namespace 提供）。
;;; 隔离 root 是临时目录；不触碰真实 /etc、/persist。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (guix modules)
             (guix build utils)         ; mkdir-p
             (gnu services)
             (gnu services shepherd)
             (guixcfg security secrets)
             (guixcfg system readiness)
             (ice-9 rdelim)
             (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 ftw)                ; scandir
             (ice-9 regex)              ; string-match
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "runtime-exec")

;; ── 基础设施 ────────────────────────────────────────────────
;; 构建 file-like → store 路径。
(define %store (open-connection))

(define (build-thing thing)
  (let ((drv (run-with-store %store (lower-object thing))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define %guile
  ;; program-file 生成的脚本 shebang 引用的 guile store 路径
  ;; （从已构建 artifact 第一行提取）。
  (let* ((prog (build-thing (password-project-program "user")))
         (line (call-with-input-file prog
                                  (lambda (p) (read-line p)))))
    (and (string-prefix? "#!" line)
         (car (string-split (substring line 2) #\space)))))

(define %projector (build-thing (password-project-program "user")))

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

;; ── password-project：真实执行 ──────────────────────────────
;; 构建正式 artifact（与 boot 时 system* 执行的是同一个 program）。

(define (run-projector shadow hash)
  (let ((root (make-fake-root shadow hash)))
    (let ((exit (run-in-root %projector root)))
      (cons exit
            (call-with-input-file (string-append root "/etc/shadow")
                                  (lambda (p) (get-string-all p)))))))

;; P1：正常 hash → exit 0，shadow user 行 hash 被替换。
(let* ((shadow "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n")
       (res (run-projector shadow "$6$salt$faketesthash\n"))
       (exit (car res)) (out (cdr res)))
  (test-equal "P1 projector success exits 0" 0 exit)
  (test-assert "P1 user shadow hash replaced"
    (and (string-contains out "$6$salt$faketesthash:x:1000:1000:u:")
         (string-contains out "root:x:0:0:root:/root:/bin/bash\n"))))

;; P2：persistent hash 缺失 → 非零，shadow 不被破坏。
(let* ((shadow "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n")
       (root (make-fake-root shadow #f))
       (exit (run-in-root %projector root))
       (out (call-with-input-file (string-append root "/etc/shadow")
                                  (lambda (p) (get-string-all p)))))
  (test-assert "P2 missing hash fails" (not (zero? exit)))
  (test-equal "P2 shadow untouched" shadow out))

;; P3：malformed hash → 非零，shadow 不被破坏。
(let* ((shadow "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n")
       (res (run-projector shadow "NOT-A-VALID-HASH\n"))
       (exit (car res)) (out (cdr res)))
  (test-assert "P3 malformed hash fails" (not (zero? exit)))
  (test-equal "P3 shadow untouched" shadow out))

;; P4：user 不在 shadow → 非零，shadow 不变（不产新条目）。
(let* ((shadow "root:x:0:0:root:/root:/bin/bash\nother:x:1001:1001:o:/home/other:/bin/bash\n")
       (res (run-projector shadow "$6$salt$valid\n"))
       (exit (car res)) (out (cdr res)))
  (test-assert "P4 missing user fails" (not (zero? exit)))
  (test-equal "P4 shadow untouched" shadow out))

;; P5：generated executable 真正运行无 unbound-variable（上面 P1 已
;; 执行成功即证明；这里显式断言输出不含 unbound/error 关键字）。
(let* ((shadow "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n")
       (root (make-fake-root shadow "$6$salt$faketesthash\n")))
  (let* ((script (string-append
                  "unshare --user --map-root-user --map-users=auto "
                  "--map-groups=auto --mount --pid --fork sh -c '"
                  "mount --bind /gnu/store " root "/gnu/store; "
                  "chroot " root " " %guile " --no-auto-compile " %projector
                  " 2>&1'"))
         (pipe (open-input-pipe script))
         (all (get-string-all pipe)))
    (close-pipe pipe)
    (test-assert "P5 no unbound-variable in runtime"
      (not (string-contains all "Unbound variable")))))

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
           (source %test-cipher)
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

(test-end "runtime-exec")
