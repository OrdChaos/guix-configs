;;; (guixcfg system deploy) argv 构造、git gate 解析与 host 枚举测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 断言对象是纯 argv 列表：pinned channels.lock.scm、绝对 -L、
;;; 正确 host module、无 shell-string 拼接、sudo 边界、
;;; reconfigure -n 不经过 tools/reconfigure.sh、update 用可变
;;; channels.scm。
;;;
;;; host 枚举用 fixture 目录 tests/fixtures/hosts-scan/：vm.scm、
;;; laptop.scm、.hidden.scm（dot）、old.scm~（backup）、notes.txt
;;; （非 .scm）、#tmp.scm#（autosave）——只有前两者应进入 host ID。

(use-modules (guixcfg system deploy)
             (guixcfg utils channels)
             (guixcfg utils repository-source)
             (srfi srfi-64)
             (srfi srfi-1)
             (srfi srfi-13)   ; string-contains
             (srfi srfi-26))

(test-runner-current (test-runner-simple))

(define %root "/repo")

(define (option-value argv opt)
  (and=> (member opt argv) cadr))

(define (no-shell-metacharacters? argv)
  "argv 不得是 shell-string 拼接：任何元素都不能包含 && / ; / |。"
  (not (any (lambda (x)
              (and (string-contains x "&&")
                   (or (string-contains x ";")
                       (string-contains x "|"))))
            argv)))

;; guile error 的异常参数形态是 (key format-string irritants ...)；
;; 提取其中全部字符串做断言（不依赖 misc-error 的内部布局）。
(define (exception-strings exn-args)
  (let walk ((x exn-args))
    (cond ((string? x) (list x))
      ((pair? x) (append (walk (car x)) (walk (cdr x))))
      (else '()))))

(test-begin "deploy")

;; ---- host 枚举与校验 ----

(define %fixture-dir "tests/fixtures/hosts-scan")

(test-equal "fixture directory yields only real host files"
            '("laptop" "vm")
            (host-ids-in-directory %fixture-dir))

(test-assert "hidden/backup/non-scm/autosave are excluded"
             (let ((ids (host-ids-in-directory %fixture-dir)))
               (and (not (member ".hidden" ids))
                    (not (member "old" ids))
                    (not (member "notes" ids))
                    (not (member "tmp" ids)))))

;; 真实 hosts 目录：枚举必须与当前仓库事实一致。任何辅助 .scm 落入
;; hosts/ 都会在此失败（host ID 事实源就是该目录的文件名）。
(test-equal "real hosts directory yields exactly current hosts"
            '("laptop" "vm")
            (host-ids-in-directory "modules/guixcfg/hosts"))

(test-assert "known host id"
             (host-id? '("laptop" "vm") "vm"))

(test-assert "unknown host id"
             (not (host-id? '("laptop" "vm") "desktop")))

(test-assert "missing host (empty arg)"
             (not (host-id? '("laptop" "vm") "")))

(test-assert "\"all\" is not a host id (command-level keyword)"
             (not (host-id? '("laptop" "vm") "all")))

(test-assert "require-host-id returns the id when known"
             (equal? "vm" (require-host-id '("laptop" "vm") "vm")))

;; fail closed：unknown host 报错，绝不 fallback；错误信息列出可用 host。
(test-assert "require-host-id fails closed on unknown host and lists known hosts"
             (let ((msg (string-join
                         (exception-strings
                          (catch #t
                            (lambda () (require-host-id '("laptop" "vm") "server") '())
                            (lambda (key . args) args)))
                         " ")))
               (and (string-contains msg "known hosts:")
                    (string-contains msg "laptop")
                    (string-contains msg "vm")
                    (string-contains msg "server"))))

(test-equal "host-source-relative-path"
            "modules/guixcfg/hosts/vm.scm"
            (host-source-relative-path "vm"))

(test-equal "host-source-absolute-path"
            "/repo/modules/guixcfg/hosts/laptop.scm"
            (host-source-absolute-path "/repo" "laptop"))

;; ---- build-os ----

(define build-argv (system-build-argv %root "vm"))

(test-assert "build-os uses pinned channels.lock.scm"
             (and (member "time-machine" build-argv)
                  (member "-C" build-argv)
                  (member "/repo/channels.lock.scm" build-argv)))

(test-equal "build-os -L is absolute"
            "/repo/modules"
            (option-value build-argv "-L"))

(test-equal "build-os targets the host module (authoritative relative path)"
            "modules/guixcfg/hosts/vm.scm"
            (last build-argv))

(test-assert "build-os argv has no shell metacharacters"
             (no-shell-metacharacters? build-argv))

(test-assert "build-os normal mode has no --dry-run"
             (not (member "--dry-run" build-argv)))

(define build-dry-argv (system-build-argv %root "laptop" #:dry-run? #t))

(test-assert "build-os dry-run maps to guix --dry-run"
             (and (member "--dry-run" build-dry-argv)
                  (equal? "modules/guixcfg/hosts/laptop.scm" (last build-dry-argv))))

;; ---- reconfigure ----

(define reconfigure-dry-argv (system-reconfigure-dry-run-argv %root "vm"))

(test-assert "reconfigure -n runs guix system reconfigure --dry-run"
             (let ((tail (cdr (member "--" reconfigure-dry-argv))))
               (and (equal? (take tail 4) '("system" "reconfigure" "--dry-run" "-L"))
                    (equal? "/repo/modules" (option-value reconfigure-dry-argv "-L")))))

(test-assert "reconfigure -n never enters the privileged transaction (no sudo, no script)"
             (and (not (member "sudo" reconfigure-dry-argv))
                  (not (any (cut string-contains <> "reconfigure.sh") reconfigure-dry-argv))))

(test-equal "reconfigure privileged handoff: sudo re-executes the same blue with explicit blueprint"
            '("sudo" "/store/blue" "-f" "/repo/blueprint.scm" ".reconfigure-root" "vm" "alice")
            (reconfigure-privileged-argv "/store/blue" "/repo/blueprint.scm" "vm" "alice"))

(test-assert "privileged handoff argv has no shell metacharacters"
             (no-shell-metacharacters?
              (reconfigure-privileged-argv "/store/blue" "/repo/blueprint.scm" "vm" "alice")))

(test-equal "system-reconfigure-argv (transaction core) is pinned and absolute -L"
            '("guix" "time-machine" "-C" "/repo/channels.lock.scm" "--"
                     "system" "reconfigure" "-L" "/repo/modules" "modules/guixcfg/hosts/vm.scm")
            (system-reconfigure-argv %root "vm"))

(test-assert "system-reconfigure-argv (normal) has no --dry-run"
             (not (member "--dry-run" (system-reconfigure-argv %root "vm"))))

;; ---- update ----

(define update-argv (channel-lock-refresh-argv %root))

(test-assert "update resolves mutable channels.scm (not the lock)"
             (and (member "/repo/channels.scm" update-argv)
                  (not (member "/repo/channels.lock.scm" update-argv))))

(test-equal "update runs guix describe -f channels"
            '("describe" "-f" "channels")
            (cdr (member "--" update-argv)))

(test-assert "update argv has no shell metacharacters"
             (no-shell-metacharacters? update-argv))

;; ---- git gate ----

(test-assert "porcelain output: empty is clean"
             (porcelain-output-clean? ""))

(test-assert "porcelain output: whitespace-only is clean"
             (porcelain-output-clean? "  \n\t"))

(test-assert "porcelain output: modified file is dirty"
             (not (porcelain-output-clean? " M docs/architecture/graphics.md\n")))

(test-assert "porcelain output: untracked file is dirty"
             (not (porcelain-output-clean? "?? tests/test-x.scm\n")))

;; ---- 只读检查素材 ----

(test-assert "repository channels structure is compatible"
             (channels-structure-ok? (repository-root)))

;; facts-resolution-report：套件环境统一注入有效 facts（run-tests.scm），
;; 此处应解析为 ok 且含 boot-critical fact；覆盖无效 override 的
;; invalid 收敛路径（GUIX_CONFIG_FACTS 指向缺失文件）。
(test-assert "facts report ok under suite facts environment"
             (eq? 'ok (car (facts-resolution-report))))

(test-assert "facts report converges to invalid on missing override"
             (let ((saved (getenv "GUIX_CONFIG_FACTS")))
               (dynamic-wind
                (lambda () (setenv "GUIX_CONFIG_FACTS" "/tmp/guixcfg-no-such-facts.scm"))
                (lambda () (eq? 'invalid (car (facts-resolution-report))))
                (lambda ()
                  (if saved (setenv "GUIX_CONFIG_FACTS" saved)
                    (unsetenv "GUIX_CONFIG_FACTS"))))))

(test-end)
