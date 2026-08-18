;;; 安装收尾 identity 兜底测试（阶段 6 防漏）：
;;;   - identity 缺失 + runtime identity 可用 → 自动安装（0700/0600）
;;;   - identity 缺失 + 无 runtime identity → fail fast（明确报错）
;;;   - identity 已就位 → no-op
;;;
;;; 场景：fresh install 漏装阶段 6 → 首次 boot secrets-deploy 失败 →
;;; login barrier 卡死（已两次实测）。cmd-commit-root 现在兜底自动
;;; 安装（或 fail fast 提示先 unlock）。

(use-modules (ice-9 rdelim)
             (ice-9 ftw)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; 加载 tools/disk-install.scm（去末尾 main 调用——测试内不触发 CLI）。
(let ((s (call-with-input-file "tools/disk-install.scm"
                              (lambda (p) (read-string p)))))
  (eval-string
   (string-join (filter (lambda (l) (not (string=? l "(main (command-line))")))
                        (string-split s #\newline))
                "\n")))

(test-begin "install-identity")

;; T1：缺失 + runtime 可用 → 自动安装（目录 0700、identity 0600）
(let* ((root (mkdtemp "/tmp/guixcfg-id-test-XXXXXX"))
       (runtime (string-append root "/runtime-identity"))
       (target (string-append root "/mnt")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append target "/persist/system/keys"))
     (call-with-output-file runtime
                            (lambda (p) (display "test-identity\n" p)))
     (chmod runtime #o600)
     (ensure-installed-identity! target runtime)
     (let ((installed (string-append target "/persist/system/keys/age/identity")))
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
     (mkdir-p (string-append target "/persist/system/keys"))
     (test-assert "T2: missing identity without runtime fails with clear error"
                  (catch #t
                    (lambda ()
                      (ensure-installed-identity! target
                                                  (string-append root "/no-runtime"))
                      #f)
                    (lambda (k . a)
                      (and (eq? k 'misc-error)
                           (string-contains (car (caddr a))
                                            "identity missing"))))))
   (lambda ()
     (false-if-exception (delete-file-recursively root)))))

;; T3：已就位 → no-op（不报错、不覆盖）
(let* ((root (mkdtemp "/tmp/guixcfg-id-test3-XXXXXX"))
       (target (string-append root "/mnt")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (mkdir-p (string-append target "/persist/system/keys/age"))
     (call-with-output-file (string-append target "/persist/system/keys/age/identity")
                            (lambda (p) (display "existing" p)))
     (chmod (string-append target "/persist/system/keys/age/identity") #o600)
     ;; 即使 runtime 不存在也不报错（已就位 = 完成）
     (ensure-installed-identity! target (string-append root "/no-runtime"))
     (test-assert "T3: existing identity untouched"
                  (string=? "existing"
                            (call-with-input-file
                                (string-append target "/persist/system/keys/age/identity")
                              (lambda (p) (read-string p))))))
   (lambda ()
     (false-if-exception (delete-file-recursively root)))))

(test-end "install-identity")
