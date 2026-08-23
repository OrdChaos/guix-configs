;;; 安装收尾 identity 兜底测试（installation 阶段 5 防漏）：
;;;   - identity 缺失 + runtime identity 可用 → 自动安装（0700/0600）
;;;   - identity 缺失 + 无 runtime identity → fail fast（明确报错）
;;;   - identity 已就位 → no-op
;;;
;;; 场景：fresh install 漏装阶段 5 → 首次 boot secrets-deploy 失败 →
;;; login barrier 卡死（已两次实测）。commit-root 兜底自动安装（或
;;; fail fast 提示先 unlock）。被测函数在 (guixcfg security age)。

(use-modules (guixcfg security age)
             (guix build utils)          ; mkdtemp
             (ice-9 rdelim)
             (ice-9 textual-ports)       ; call-with-output-string
             (ice-9 ftw)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "install-identity")

;; T1：缺失 + runtime 可用 → 自动安装（目录 0700、identity 0600）
(let* ((root (mkdtemp "/tmp/guixcfg-id-test-XXXXXX"))
       (runtime (string-append root "/runtime-identity"))
       (target (string-append root "/mnt")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append target (dirname (%installed-identity-path))))
     (call-with-output-file runtime
                            (lambda (p) (display "test-identity\n" p)))
     (chmod runtime #o600)
     (ensure-installed-identity! target runtime)
     (let ((installed (string-append target (%installed-identity-path))))
       (test-assert "T1: identity auto-installed from runtime"
                    (file-exists? installed))
       (test-assert "T1: identity mode 0600"
                    (= #o600 (logand (stat:mode (stat installed)) #o777)))
       (test-assert "T1: keys/age dir mode 0700"
                    (= #o700 (logand (stat:mode (stat (dirname installed))) #o777)))))
   (lambda ()
     (false-if-exception (delete-file-recursively root)))))

;; T2：缺失 + 无 runtime → fail fast（明确报错，不静默）
(let* ((root (mkdtemp "/tmp/guixcfg-id-test2-XXXXXX"))
       (target (string-append root "/mnt")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append target (dirname (%installed-identity-path))))
     (test-assert "T2: missing identity without runtime fails with clear error"
                  (catch #t
                    (lambda ()
                      (ensure-installed-identity! target
                                                  (string-append root "/no-runtime"))
                      #f)
                    ;; misc-error 的 args 结构随宿主 error flavor 变化
                    ;;（（#f "~A" (msg) #f）与（#f msg () #f）都出现过）——
                    ;; 在整个 args 上检索消息，不做位置假设。
                    (lambda (k . a)
                      (and (eq? k 'misc-error)
                           (string-contains
                            (call-with-output-string
                             (lambda (p) (write a p)))
                            "identity missing"))))))
   (lambda ()
     (false-if-exception (delete-file-recursively root)))))

;; T3：已就位 → no-op（不报错、不覆盖）
(let* ((root (mkdtemp "/tmp/guixcfg-id-test3-XXXXXX"))
       (target (string-append root "/mnt")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append target (dirname (%installed-identity-path))))
     (call-with-output-file (string-append target (%installed-identity-path))
                            (lambda (p) (display "existing" p)))
     (chmod (string-append target (%installed-identity-path)) #o600)
     ;; 即使 runtime 不存在也不报错（已就位 = 完成）
     (ensure-installed-identity! target (string-append root "/no-runtime"))
     (test-assert "T3: existing identity untouched"
                  (string=? "existing"
                            (call-with-input-file
                             (string-append target (%installed-identity-path))
                             (lambda (p) (read-string p))))))
   (lambda ()
     (false-if-exception (delete-file-recursively root)))))

(test-end "install-identity")
