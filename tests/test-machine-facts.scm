;;; machine facts 路径解析与 fail-closed 测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 语义边界（2026-09 ESP UUID 文件改造后）：
;;;   - facts 的解析/校验机制（本文件 1-11）不变；
;;;   - OS 构造（cryptroot-mapped-devices）不再消费 facts——LUKS UUID
;;;     由 initrd 运行时从 ESP %esp-luks-uuid-file 读取，OS/initrd
;;;     derivation 与机器 UUID 无关（本文件 12-14 断言这一点）。

(use-modules (srfi srfi-64)
             (srfi srfi-1)                ; 字符串扁平化提取
             (srfi srfi-13)               ; string-contains
             (ice-9 textual-ports)        ; get-string-all
             (gnu system mapped-devices)) ; mapped-device-source

;; guile 3.0.11 的 error 异常参数形态是 (key format-string irritants ...)，
;; 消息可能嵌在 irritants 里；提取其中全部字符串做断言（对 misc-error
;; 内部布局不敏感）。
(define (exception-strings exn-args)
  (let walk ((x exn-args))
    (cond ((string? x) (list x))
      ((pair? x) (append (walk (car x)) (walk (cdr x))))
      (else '()))))

(define %test-facts
  '((luks-uuid . "00000000-0000-0000-0000-000000000000")))

(define %tmp-dir
  (string-append "/tmp/guixcfg-test-facts-dir-"
                 (number->string (getpid))))

(mkdir %tmp-dir)

;; machine-facts 机制模块（channel-free）；file-systems 只取
;; cryptroot-mapped-devices 做集成断言。
(define mf (resolve-module '(guixcfg system machine-facts)))
(define (mf-ref name) (module-ref mf name))
(define fs (resolve-module '(guixcfg system file-systems)))
(define (fs-ref name) (module-ref fs name))
(define resolve-facts-path (mf-ref 'resolve-facts-path))
(define load-machine-facts (mf-ref 'load-machine-facts))
(define require-fact (mf-ref 'require-fact))

(test-begin "machine-facts")

(let ((default-file (string-append %tmp-dir "/default.scm"))
      (custom-file (string-append %tmp-dir "/custom.scm"))
      (missing-file (string-append %tmp-dir "/missing.scm"))
      (bad-file (string-append %tmp-dir "/bad.scm"))
      (truncated-file (string-append %tmp-dir "/truncated.scm")))
  (call-with-output-file default-file
                         (lambda (p)
                           (write '((luks-uuid . "11111111-1111-1111-1111-111111111111")) p)
                           (newline p)))
  (call-with-output-file custom-file
                         (lambda (p)
                           (write '((luks-uuid . "22222222-2222-2222-2222-222222222222")) p)
                           (newline p)))
  (call-with-output-file bad-file
                         (lambda (p) (write '("not" "an" "alist") p)))
  (call-with-output-file truncated-file
                         (lambda (p) (display "((luks-uuid . \"abc" p)))
  
  ;; 1. explicit override wins over default path
  (test-equal "explicit override wins over default path"
              custom-file
              (resolve-facts-path custom-file default-file))
  ;; 2. 已安装系统自动发现：无 override 时默认路径
  (test-equal "default path auto-discovered without override"
              default-file
              (resolve-facts-path #f default-file))
  ;; 3. 都没有 → 无 facts
  (test-equal "returns #f without facts"
              #f
              (resolve-facts-path #f missing-file))
  ;; 4. 空字符串视为未设置
  (test-equal "empty-string override treated as unset (default exists)"
              default-file
              (resolve-facts-path "" default-file))
  (test-equal "empty-string override treated as unset (no default)"
              #f
              (resolve-facts-path "" missing-file))
  ;; 5. 显式 override 文件不存在 → 显式拒绝
  (test-error "missing override file -> explicit error"
              #t
              (resolve-facts-path missing-file default-file))
  ;; 6. 显式 override 是目录 → 显式拒绝
  (test-error "override is a directory -> explicit error"
              #t
              (resolve-facts-path %tmp-dir default-file))
  ;; 7. default path is a directory -> explicit error（异常状态，不静默当无 facts）
  (test-error "default path is a directory -> explicit error"
              #t
              (resolve-facts-path #f %tmp-dir))
  ;; 8. 格式非法 → 显式拒绝
  (test-error "facts content not an alist -> explicit error"
              #t
              (load-machine-facts bad-file))
  (test-error "unparseable facts -> explicit error"
              #t
              (load-machine-facts truncated-file))
  ;; 9. require-fact：缺失立即失败（fail-closed）
  (test-error "missing required fact -> immediate error"
              #t
              (require-fact '() 'luks-uuid))
  (test-equal "returns value when required fact present"
              "00000000-0000-0000-0000-000000000000"
              (require-fact %test-facts 'luks-uuid))
  ;; 10. 正确读取文件内容
  (test-equal "load-machine-facts reads luks-uuid correctly"
              "11111111-1111-1111-1111-111111111111"
              (assq-ref (load-machine-facts default-file) 'luks-uuid))
  ;; 11. 错误消息必须可诊断（而不是 unbound variable 之类）
  (test-assert "error message includes path when override missing"
               (let ((msg (string-join
                           (exception-strings
                            (catch #t
                              (lambda ()
                                (resolve-facts-path missing-file default-file)
                                '())
                              (lambda (key . args) args)))
                           " ")))
                 (string-contains msg "GUIX_CONFIG_FACTS points to a missing file")))
  (test-assert "error message includes fact name when luks-uuid missing"
               (let ((msg (string-join
                           (exception-strings
                            (catch #t
                              (lambda ()
                                (require-fact '() 'luks-uuid)
                                '())
                              (lambda (key . args) args)))
                           " ")))
                 (string-contains msg "missing required machine fact"))))

;; 12. 集成：正式 root LUKS mapped-device source 是固定哨兵（LUKS UUID
;;     不进 OS derivation——initrd 运行时从 ESP %esp-luks-uuid-file
;;     读取），绝不是 facts 的 uuid 值或 /dev/disk/by-partlabel/ 路径。
(let ((md (car ((fs-ref 'cryptroot-mapped-devices)))))
  (test-equal "root LUKS mapped-device source is the constant sentinel"
              "luks-uuid-from-esp"
              (mapped-device-source md)))

;; 13. 无 facts 时 OS 构造必须成功（子进程）：GUIX_CONFIG_FACTS 指向不
;;     存在文件会显式报错（override 语义），但不设 facts / facts 缺
;;     luks-uuid 时构造 mapped-device 不再失败——UUID 是运行时事实。
(define (repro-construct env-value)
  "在子进程（guix time-machine repl）中加载 file-systems 并构造 root
mapped-device，返回 (rc . stderr)。ENV-VALUE 为 #f 时不设置
GUIX_CONFIG_FACTS。"
  (let* ((script (string-append %tmp-dir "/repro.scm"))
         (err-file (string-append %tmp-dir "/repro.err")))
    (call-with-output-file script
                           (lambda (p)
                             (display "(add-to-load-path (string-append (getcwd) \"/modules\"))\n" p)
                             (display "(use-modules (guixcfg system file-systems))\n" p)
                             (display "(car ((@ (guixcfg system file-systems) cryptroot-mapped-devices)))\n" p)))
    (let ((rc (system* "sh" "-c"
                       (string-append (if env-value
                                        (string-append "GUIX_CONFIG_FACTS=" env-value " ")
                                        "")
                                      " guix time-machine -C channels.lock.scm"
                                      " -- repl -L modules -- " script
                                      " >/dev/null 2>" err-file))))
      (cons (status:exit-val rc)
            (call-with-input-file err-file get-string-all)))))

;; 14. derivation 与 facts 无关（子进程，本改造的目标性质）：
;;     两个不同 luks-uuid 求值出的 initrd 与整系统 derivation 路径
;;     都逐字节相同。
(define (drv-under-facts facts-file)
  "子进程计算 %lenovo-legion-y7000p-os 的 initrd 与 system derivation
路径（两行 stdout）；返回 (rc initrd-drv system-drv)。"
  (let* ((script (string-append %tmp-dir "/drv.scm"))
         (out-file (string-append %tmp-dir "/drv.out")))
    (call-with-output-file script
                           (lambda (p)
                             (display "(add-to-load-path (string-append (getcwd) \"/modules\"))\n" p)
                             (display "(use-modules (guix store) (guix monads) (guix gexp) (guix derivations) (gnu system) (guixcfg hosts lenovo-legion-y7000p))\n" p)
                             (display "(define store (open-connection))\n" p)
                             (display "(display (derivation-file-name (run-with-store store (lower-object (operating-system-initrd-file %lenovo-legion-y7000p-os))))) (newline)\n" p)
                             (display "(display (derivation-file-name (run-with-store store (operating-system-derivation %lenovo-legion-y7000p-os)))) (newline)\n" p)))
    (let ((rc (system* "sh" "-c"
                       (string-append "GUIX_CONFIG_FACTS=" facts-file
                                      " guix time-machine -C channels.lock.scm"
                                      " -- repl -L modules -- " script
                                      " >" out-file " 2>/dev/null"))))
      (let ((lines (string-split
                    (string-trim-both
                     (call-with-input-file out-file get-string-all))
                    #\newline)))
        (list rc (and (pair? lines) (car lines))
              (and (pair? lines) (pair? (cdr lines)) (cadr lines)))))))

(if (zero? (status:exit-val (system* "guix" "--version")))
  (let ((no-luks (string-append %tmp-dir "/no-luks.scm"))
        (facts-a (string-append %tmp-dir "/facts-a.scm"))
        (facts-b (string-append %tmp-dir "/facts-b.scm")))
    (call-with-output-file no-luks
                           (lambda (p)
                             (write '((foo . 1)) p)
                             (newline p)))
    (call-with-output-file facts-a
                           (lambda (p)
                             (write '((luks-uuid . "00000000-0000-0000-0000-000000000000")) p)
                             (newline p)))
    (call-with-output-file facts-b
                           (lambda (p)
                             (write '((luks-uuid . "11111111-1111-1111-1111-111111111111")) p)
                             (newline p)))
    (let ((r (repro-construct no-luks)))
      (test-assert "facts lack luks-uuid: mapped-device constructs (UUID is runtime)"
                   (and (zero? (car r))
                        (not (string-contains (cdr r) "unbound variable")))))
    (let ((a (drv-under-facts facts-a))
          (b (drv-under-facts facts-b)))
      (test-assert "derivations computed under both facts"
                   (and (zero? (car a)) (zero? (car b))
                        (cadr a) (caddr a)
                        (string-suffix? ".drv" (cadr a))))
      (test-equal "initrd derivation is identical for different luks-uuid"
                  (cadr a) (cadr b))
      (test-equal "system derivation is identical for different luks-uuid"
                  (caddr a) (caddr b))))
  (format (current-error-port)
          "subprocess integration test skipped: no guix in PATH~%"))

(test-end)
