;;; 测试运行器。模块代码使用 (guix records)，所以需要 Guix 的模块路径，
;;; 通过锁定频道运行（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
;;;   guix time-machine -C channels.lock.scm -- repl -- tests/run-tests.scm --apps
;;; 全部通过时退出码为 0，有失败时退出码为 1。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path；
;; 另外把 pinned Nonguix / Virelith channel 源（store 中的 checkout）
;; 加入——(guixcfg system kernel-platform)（M1）依赖 (nongnu packages
;; linux)，(guixcfg home fonts) 依赖 (virelith packages fonts)，guix
;; repl 不会自动带上 channel 模块路径。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guix channels)     ; channel-name、channel-commit（解析 lock）
             (srfi srfi-1)
             (srfi srfi-13)
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
(define %saayix-store-dir (channel-store-dir 'saayix))
(define %rosenthal-store-dir (channel-store-dir 'rosenthal))
(define %bluebox-store-dir (channel-store-dir 'bluebox))
(define %rust-toolchain-store-dir (channel-store-dir 'guix-rust-toolchain))

(add-to-load-path %nonguix-store-dir)
(add-to-load-path %virelith-store-dir)
(add-to-load-path %saayix-store-dir)
(add-to-load-path %rosenthal-store-dir)
(add-to-load-path %bluebox-store-dir)
(add-to-load-path %rust-toolchain-store-dir)

;; Repository-local .go files are developer cache, not test inputs. Loading
;; stale or interrupted ccache objects can split Guix record identities.
(set! %load-compiled-path
  (filter (lambda (path)
            (not (string-contains path "/.cache/guile/ccache/")))
          %load-compiled-path))

(primitive-load "tests/manifest.scm")

(define %test-arguments (cdr (program-arguments)))

(unless (and (every (lambda (arg) (member arg '("--apps" "--all")))
                    %test-arguments)
             (<= (length %test-arguments) 1))
  (error "usage: tests/run-tests.scm [--apps|--all]" %test-arguments))

(define %test-mode
  (cond ((member "--all" %test-arguments) 'all)
    ((member "--apps" %test-arguments) 'apps)
    (else 'core)))

(define %discovered-test-files
  (sort (map (lambda (name) (string-append "tests/" name))
             (scandir "tests"
                      (lambda (name)
                        (and (string-prefix? "test-" name)
                             (string-suffix? ".scm" name)))))
        string<?))

(define %classified-test-files
  (sort (append %core-test-files %app-test-files) string<?))

(unless (and (equal? %discovered-test-files %classified-test-files)
             (= (length %classified-test-files)
                (length (delete-duplicates %classified-test-files))))
  (error "test manifest is incomplete or contains duplicates"
         %discovered-test-files %classified-test-files))

;; 必须先设置 runner，再加载测试文件：
;; SRFI-64 的计数器都记录在“当前 runner”上。
(test-runner-current (test-runner-simple))

;; 全套测试在临时 facts 环境下运行（不碰真实宿主 /persist）。OS 构造
;; 本身已不消费 facts（LUKS UUID 是 initrd 运行时事实，见
;; (guixcfg system file-systems)），但 deploy/enroll 等运行时校验路径
;; 仍按 GUIX_CONFIG_FACTS 解析 facts——显式提供测试 UUID，语义稳定。
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
             (case %test-mode
               ((apps) %app-test-files)
               ((all) (append %core-test-files %app-test-files))
               (else %core-test-files))))
 (lambda ()
   (unsetenv "GUIX_CONFIG_FACTS")
   (when (file-exists? %test-facts-file)
     (delete-file %test-facts-file))))

(exit (zero? (+ %fail-total %xfail-total)))
