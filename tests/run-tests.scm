;;; 测试运行器。模块代码使用 (guix records)，所以需要 Guix 的模块路径，
;;; 通过锁定频道运行（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
;;; 全部通过时退出码为 0，有失败时退出码为 1。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path；
;; 另外把 pinned Nonguix / Virelith channel 源（store 中的 checkout）
;; 加入——(guixcfg system kernel-platform)（M1）依赖 (nongnu packages
;; linux)，(guixcfg home fonts) 依赖 (virelith packages fonts)，guix
;; repl 不会自动带上 channel 模块路径。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guix channels)     ; channel-name、channel-commit（解析 lock）
             (srfi srfi-1)
             (ice-9 ftw)         ; scandir
             (srfi srfi-64))

(define (channel-store-dir name)
  ;; store 中 pinned channel 源（channel 内容是内容寻址的：
  ;; channels.lock.scm 锁定的 commit 对应唯一 store 路径）。缺失时
  ;; 明确报错（先跑一次 time-machine 下载 channel 源）。
  (let* ((lock (eval (call-with-input-file "channels.lock.scm" read)
                     (current-module)))
         (commit (channel-commit
                  (find (lambda (ch) (eq? (channel-name ch) name))
                        lock)))
         ;; store 中 channel 源目录名用 7 字符短 hash。
         (short (substring commit 0 7))
         (hits (scandir "/gnu/store"
                        (lambda (dir)
                          (string-contains dir
                                           (string-append "-" (symbol->string name)
                                                          "-" short))))))
    (if (pair? hits)
      (string-append "/gnu/store/" (car hits))
      (error "channel source not in store; run time-machine first"
             name commit))))

(define %nonguix-store-dir (channel-store-dir 'nonguix))
(define %virelith-store-dir (channel-store-dir 'virelith))

(add-to-load-path %nonguix-store-dir)
(add-to-load-path %virelith-store-dir)

;; 必须先设置 runner，再加载测试文件：
;; SRFI-64 的计数器都记录在“当前 runner”上。
(test-runner-current (test-runner-simple))

;; (guixcfg hosts vm) 会加载 (guixcfg system file-systems)，其顶层对
;; luks-uuid 做 fail-closed 检查（无 facts 时模块加载即报错）。因此全套
;; 测试在临时 facts 环境下运行（不碰真实宿主 /persist）：显式提供测试
;; UUID，让 modules-compile、%os 实例化等测试可以正常加载 host 模块。
(define %test-facts-file
  (string-append "/tmp/guixcfg-test-facts-"
                 (number->string (getpid)) ".scm"))

(call-with-output-file %test-facts-file
                       (lambda (port)
                         (write '((luks-uuid . "00000000-0000-0000-0000-000000000000")) port)
                         (newline port)))

;; 每个测试文件都调用 (test-runner-current (test-runner-simple))，把
;; 当前 runner 换成自己的新 runner——最后的 runner 只反映最后一个
;; 文件，直接看 (test-runner-current) 会让前面套件的失败被掩盖。
;; 这里在每个文件加载后立刻摘取其 runner 的计数，累计判定退出码。
(define %fail-total 0)
(define %xfail-total 0)

(define (run-file file)
  (primitive-load file)
  (let ((r (test-runner-current)))
    (set! %fail-total (+ %fail-total (test-runner-fail-count r)))
    (set! %xfail-total (+ %xfail-total (test-runner-xfail-count r)))))

(dynamic-wind
 (lambda () (setenv "GUIX_CONFIG_FACTS" %test-facts-file))
 (lambda ()
   (for-each run-file
             '("tests/test-atomic-file.scm"
               "tests/test-boot-state.scm"
               "tests/test-process.scm"
               "tests/test-spawn.scm"
               "tests/test-model.scm"
               "tests/test-policies.scm"
               "tests/test-plan.scm"
               "tests/test-validate.scm"
               "tests/test-device.scm"
               "tests/test-root-generation.scm"
               "tests/test-modules-load.scm"
               "tests/test-machine-facts.scm"
               "tests/test-luks-passphrase.scm"
               "tests/test-tpm2-state.scm"
               "tests/test-tpm-unlock.scm"
               "tests/test-recovery.scm"
               "tests/test-uki-menu.scm"
               "tests/test-device-resolver.scm"
               "tests/test-commit-root.scm"
               "tests/test-install-identity.scm"
               "tests/test-tpm2-enroll.scm"
               "tests/test-credential-source.scm"
               "tests/test-kernel-platform.scm"
               "tests/test-substitutes.scm"
               "tests/test-desktop.scm"
               "tests/test-session-env.scm"
               "tests/test-apps.scm"
               "tests/test-home.scm"
               "tests/test-application-persistence.scm"
               "tests/test-source-hygiene.scm"
               "tests/test-machine-state-persistence.scm"
               "tests/test-mixed-authority.scm"
               "tests/test-mpv.scm"
               "tests/test-google-chrome.scm"
               "tests/test-xdg.scm"
               "tests/test-fonts.scm"
               "tests/test-gnome-keyring.scm"
               "tests/test-ui-language.scm"
               "tests/test-ssh.scm"
               "tests/test-user-persistence.scm"
               "tests/test-session.scm"
               "tests/test-home.scm"
               "tests/test-home-pivot.scm"
               "tests/test-users.scm"
               "tests/test-age.scm"
               "tests/test-secrets.scm"
               "tests/test-accounts.scm"
               "tests/test-runtime-exec.scm"
               "tests/test-store-leakage.scm"
               "tests/test-readiness.scm")))
 (lambda ()
   (unsetenv "GUIX_CONFIG_FACTS")
   (when (file-exists? %test-facts-file)
     (delete-file %test-facts-file))))

(exit (zero? (+ %fail-total %xfail-total)))
