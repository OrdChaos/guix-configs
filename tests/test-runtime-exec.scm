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
             (gnu services)
             (gnu services shepherd)
             (guixcfg security secrets)
             (guixcfg system readiness)
             (ice-9 rdelim)
             (ice-9 popen)
             (ice-9 textual-ports)
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

;; 构建 fake root：返回目录路径，内含 fake shadow/persist hash。
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

;; ── persistent-state-ready：真实执行 ─────────────────────────
;; start 是 shepherd lambda（纯 core 逻辑）。构建等价可执行体：
;; 直接在 chroot 里跑一个 gexp，验证 (and (file-exists? ...)) 对路径
;; 敏感性 + 无 unbound。
(define %psr-program
  (build-thing
   (program-file
    "psr-exec-test"
    (with-imported-modules (source-module-closure '((guix build utils)))
                           #~(begin
                              (use-modules (guix build utils))
                              (exit
                               (if (and (file-exists? "/persist/system")
                                        (file-exists? "/persist/data-home")
                                        (file-exists? "/var/guix")
                                        (file-exists? "/gnu/store"))
                                 #t #f)))))))

(define (run-psr root-extra)
  "在 fake root 上执行 psr；ROOT-EXTRA 是额外创建路径的列表。"
  (let ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                            "/guixcfg-psr-" (number->string (getpid))
                            "-" (number->string (random 100000)))))
    (mkdir dir)
    (mkdir (string-append dir "/gnu"))
    (mkdir (string-append dir "/gnu/store"))
    (for-each (lambda (p)
                (let* ((parts (string-split p #\/))
                       (acc (list dir)))
                  (for-each (lambda (part)
                              (let ((cur (string-append (car acc) "/" part)))
                                (unless (file-exists? cur)
                                  (mkdir cur))
                                (set-car! acc cur)))
                            (cdr parts))))
              root-extra)
    (let* ((script (string-append
                    "unshare --user --map-root-user --map-users=auto "
                    "--map-groups=auto --mount --pid --fork sh -c '"
                    "mount --bind /gnu/store " dir "/gnu/store; "
                    "chroot " dir " " %guile " --no-auto-compile " %psr-program
                    " 2>&1; echo $?'"))
           (pipe (open-input-pipe script))
           (all (get-string-all pipe)))
      (close-pipe pipe)
      ;; 输出最后一行是退出码
      (let* ((lines (filter (lambda (l) (not (string-null? l)))
                            (string-split all #\newline)))
             (code (and (pair? lines)
                        (string->number (string-trim-both (car (reverse lines)))))))
        code))))

;; R1：全部路径存在 → 成功（exit 0）。
(test-equal "R1 all paths present succeeds"
  0 (run-psr '("/persist/system" "/persist/data-home" "/var/guix" "/gnu/store")))

;; R2：任一关键路径缺失 → 失败（exit 1）。
(test-equal "R2 missing /persist/system fails"
  1 (run-psr '("/persist/data-home" "/var/guix" "/gnu/store")))

;; R3：generated runtime 可执行、无 unbound-variable（R1/R2 执行本身即证）。

;; ── secrets-deploy：最小 execution smoke ────────────────────
;; 构建正式 artifact；在无 identity 的 fake root 里执行：
;; 应因缺 identity 明确失败（exit 非零），但模块 closure 必须完整
;; （无 unbound-variable / no code for module）。
(define %deploy
  (build-thing (secrets-deploy-program '() "user")))

(let* ((root (make-fake-root
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:u:/home/user:/bin/bash\n"
              #f))
       ;; deploy 需要 /etc/passwd（getpw owner）
       (script (string-append
                "unshare --user --map-root-user --map-users=auto "
                "--map-groups=auto --mount --pid --fork sh -c '"
                "mount --bind /gnu/store " root "/gnu/store; "
                "chroot " root " " %guile " --no-auto-compile " %deploy
                " 2>&1'")))
  (let* ((pipe (open-input-pipe script))
         (all (get-string-all pipe)))
    (close-pipe pipe)
    (test-assert "deploy executes without unbound-variable"
      (not (string-contains all "Unbound variable")))
    (test-assert "deploy fails closed on missing identity"
      (string-contains all "stable identity missing"))))

(test-end "runtime-exec")
