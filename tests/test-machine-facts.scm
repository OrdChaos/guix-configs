;;; machine facts 路径解析与 fail-closed 测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 注意：测试 facts 环境由 run-tests.scm 统一提供（GUIX_CONFIG_FACTS
;;; 指向临时文件）；本文件直接加载 (guixcfg system file-systems)。该模块
;;; 加载阶段不做任何 facts 校验（惰性），fail-closed 错误在构造
;;; mapped-device 时抛出。

(use-modules (srfi srfi-64)
             (gnu system mapped-devices)  ; mapped-device-source
             (gnu system uuid))           ; uuid、uuid=?

(define %test-facts
  '((luks-uuid . "00000000-0000-0000-0000-000000000000")))

(define %tmp-dir
  (string-append "/tmp/guixcfg-test-facts-dir-"
                 (number->string (getpid))))

(mkdir %tmp-dir)

;; file-systems 模块的内部绑定（未导出，测试经 module-ref 取用）。
(define fs (resolve-module '(guixcfg system file-systems)))
(define (fs-ref name) (module-ref fs name))
(define resolve-facts-path (fs-ref 'resolve-facts-path))
(define load-machine-facts (fs-ref 'load-machine-facts))
(define require-fact (fs-ref 'require-fact))

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
  
  ;; 1. 显式 override 优先于默认路径
  (test-equal "显式 override 优先于默认路径"
              custom-file
              (resolve-facts-path custom-file default-file))
  ;; 2. 已安装系统自动发现：无 override 时默认路径
  (test-equal "无 override 时自动发现默认路径"
              default-file
              (resolve-facts-path #f default-file))
  ;; 3. 都没有 → 无 facts
  (test-equal "无 facts 时返回 #f"
              #f
              (resolve-facts-path #f missing-file))
  ;; 4. 空字符串视为未设置
  (test-equal "空字符串 override 视为未设置（有默认）"
              default-file
              (resolve-facts-path "" default-file))
  (test-equal "空字符串 override 视为未设置（无默认）"
              #f
              (resolve-facts-path "" missing-file))
  ;; 5. 显式 override 文件不存在 → 显式拒绝
  (test-error "override 文件不存在 → 显式报错"
              #t
              (resolve-facts-path missing-file default-file))
  ;; 6. 显式 override 是目录 → 显式拒绝
  (test-error "override 是目录 → 显式报错"
              #t
              (resolve-facts-path %tmp-dir default-file))
  ;; 7. 默认路径是目录 → 显式报错（异常状态，不静默当无 facts）
  (test-error "默认路径是目录 → 显式报错"
              #t
              (resolve-facts-path #f %tmp-dir))
  ;; 8. 格式非法 → 显式拒绝
  (test-error "facts 内容非 alist → 显式报错"
              #t
              (load-machine-facts bad-file))
  (test-error "facts 无法解析 → 显式报错"
              #t
              (load-machine-facts truncated-file))
  ;; 9. require-fact：缺失立即失败（fail-closed）
  (test-error "缺失 required fact → 立即报错"
              #t
              (require-fact '() 'luks-uuid))
  (test-equal "required fact 存在时返回其值"
              "00000000-0000-0000-0000-000000000000"
              (require-fact %test-facts 'luks-uuid))
  ;; 10. 正确读取文件内容
  (test-equal "load-machine-facts 正确读出 luks-uuid"
              "11111111-1111-1111-1111-111111111111"
              (assq-ref (load-machine-facts default-file) 'luks-uuid))
  ;; 11. 错误消息必须可诊断（而不是 unbound variable 之类）
  (test-assert "override 不存在时错误消息含路径信息"
               (let ((msg (catch #t
                            (lambda ()
                              (resolve-facts-path missing-file default-file)
                              #f)
                            (lambda (key . args)
                              (cadr args)))))
                 (and (string? msg)
                      (string-contains msg "GUIX_CONFIG_FACTS 指向的文件不存在"))))
  (test-assert "缺失 luks-uuid 时错误消息含 fact 名"
               (let ((msg (catch #t
                            (lambda ()
                              (require-fact '() 'luks-uuid)
                              #f)
                            (lambda (key . args)
                              (cadr args)))))
                 (and (string? msg)
                      (string-contains msg "缺少必需的 machine fact")))))

;; 12. 集成：正式 root LUKS mapped-device source 是 facts 中的 UUID，
;;     绝不是 /dev/disk/by-partlabel/ 字符串。
(let ((md (car ((fs-ref 'cryptroot-mapped-devices)))))
  (test-assert "root LUKS mapped-device source 是 facts 中的 <uuid>"
               (uuid=? (uuid "00000000-0000-0000-0000-000000000000")
                       (mapped-device-source md))))

;; 13. 负向集成（子进程）：显式 override 指向不存在文件 / facts 缺
;;     luks-uuid 时，模块加载阶段不再吞错，构造 mapped-device 时抛出
;;     清晰错误，而不是 Scheme unbound variable。复现
;;     GUIX_CONFIG_FACTS=/mnt/persist/...（已安装系统上不存在）场景。
(define (repro-failure env-value)
  "在子进程（guix time-machine repl）中加载 file-systems 并构造 root
mapped-device，返回 (rc . stderr)；预期 rc≠0。
用 time-machine 保证子进程与主测试共享同一频道集（file-systems 依赖
Virelith 频道提供的 tpm2-tools-compat，宿主 guix 的频道不可见）。"
  (let* ((script (string-append %tmp-dir "/repro.scm"))
         (err-file (string-append %tmp-dir "/repro.err")))
    (call-with-output-file script
                           (lambda (p)
                             (display "(add-to-load-path (string-append (getcwd) \"/modules\"))\n" p)
                             (display "(use-modules (guixcfg system file-systems))\n" p)
                             (display "(car ((@ (guixcfg system file-systems) cryptroot-mapped-devices)))\n" p)))
    (let ((rc (system* "sh" "-c"
                       (string-append "GUIX_CONFIG_FACTS=" env-value
                                      " guix time-machine -C channels.lock.scm"
                                      " -- repl -L modules -- " script
                                      " >/dev/null 2>" err-file))))
      (cons (status:exit-val rc)
            (call-with-input-file err-file get-string-all)))))

(if (zero? (status:exit-val (system* "guix" "--version")))
  (let ((missing (string-append %tmp-dir "/missing-facts.scm"))
        (no-luks (string-append %tmp-dir "/no-luks.scm")))
    (call-with-output-file no-luks
                           (lambda (p)
                             (write '((foo . 1)) p)
                             (newline p)))
    (let ((r1 (repro-failure missing)))
      (test-assert "override 指向不存在文件：清晰报错，非 unbound variable"
                   (and (not (zero? (car r1)))
                        (string-contains (cdr r1)
                                         "GUIX_CONFIG_FACTS 指向的文件不存在")
                        (not (string-contains (cdr r1) "unbound variable")))))
    (let ((r2 (repro-failure no-luks)))
      (test-assert "facts 缺 luks-uuid：清晰报错，非 unbound variable"
                   (and (not (zero? (car r2)))
                        (string-contains (cdr r2) "缺少必需的 machine fact")
                        (not (string-contains (cdr r2) "unbound variable"))))))
  (format (current-error-port)
          "跳过子进程集成测试：PATH 中无 guix~%"))

(test-end)
