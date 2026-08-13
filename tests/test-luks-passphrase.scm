;;; LUKS passphrase 交互与 stdin 传递测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 覆盖：plan 不含 secret、两次输入不一致/空密码拒绝、
;;; passphrase 复用于 format/open（fake cryptsetup 捕获 stdin 与 argv）、
;;; format/open 失败传播。注意：断言一律用 test-assert 包裹比较，
;;; 避免 srfi-64 失败信息打印 passphrase 本身。

(use-modules (srfi srfi-64)
             (ice-9 rdelim)      ; read-line
             (ice-9 textual-ports)  ; get-string-all
             (guixcfg storage model)
             (guixcfg storage policies)
             (guixcfg storage plan)
             (guixcfg storage filesystem)
             (guixcfg storage install))

;; fake cryptsetup：记录 argv 与 stdin 到临时文件，退出码可配。
;; passphrase 通过真实 pipe/stdin 路径传递（open-pipe* + execvp）。
(define %fake-bin
  (string-append "/tmp/guixcfg-test-luks-bin-"
                 (number->string (getpid))))
(define %fake-argv (string-append %fake-bin "/argv.txt"))
(define %fake-stdin (string-append %fake-bin "/stdin.txt"))
(define %original-path (getenv "PATH"))

(define (install-fake-cryptsetup exit-code)
  "把假 cryptsetup 装入临时 PATH；EXIT-CODE 为模拟退出码。"
  (unless (file-exists? %fake-bin)
    (mkdir %fake-bin))
  (call-with-output-file (string-append %fake-bin "/cryptsetup")
                         (lambda (p)
                           (display "#!/bin/sh\n" p)
                           (display "printf '%s\\n' \"$*\" > \"$FAKE_LUKS_ARGV\"\n" p)
                           (display "cat > \"$FAKE_LUKS_STDIN\"\n" p)
                           (display "exit \"${FAKE_LUKS_EXIT:-0}\"\n" p)))
  (chmod (string-append %fake-bin "/cryptsetup") #o755)
  (setenv "PATH" (string-append %fake-bin ":" %original-path))
  (setenv "FAKE_LUKS_ARGV" %fake-argv)
  (setenv "FAKE_LUKS_STDIN" %fake-stdin)
  (setenv "FAKE_LUKS_EXIT" (number->string exit-code)))

(define (fake-argv)
  (false-if-exception
   (call-with-input-file %fake-argv read-line)))

(define (fake-stdin)
  (false-if-exception
   (call-with-input-file %fake-stdin get-string-all)))

(test-begin "luks-passphrase")

;; ── 1. plan 不含 secret ────────────────────────────────────
(let* ((plan (storage-plan %vm-storage-policy "/dev/vda"))
       (secret "sup3r-s3cret-value"))
  (test-assert "plan 的 detail 不含 passphrase/password/secret 键"
               (every (lambda (step)
                        (let ((keys (map car (plan-step-detail step))))
                          (not (any (lambda (k) (memq k keys))
                                    '(passphrase password secret)))))
                      plan))
  (test-assert "plan 文本不包含秘密值"
               (not (string-contains (plan->text plan) secret))))

;; ── 2. passphrase 复用于两个 operation ─────────────────────
(let ((calls 0))
  (define (reader)
    (set! calls (1+ calls))
    "pw")
  (define source (make-luks-passphrase-source reader))
  (test-assert "首次调用返回 reader 的值"
               (string=? "pw" (source)))
  (test-assert "再次调用返回同一值（不重新读取）"
               (string=? "pw" (source)))
  (test-assert "reader 只被调用一次"
               (= 1 calls)))

;; ── 3. 两次输入不一致 / 空密码：重试循环 ──────────────────
(test-assert "两次不一致后重新输入"
             (string=? "okpw"
                       (with-input-from-string "foo\nbar\nokpw\nokpw\n"
                                               (lambda () (read-luks-passphrase!)))))
(test-assert "空密码被拒绝"
             (string=? "realpw"
                       (with-input-from-string "\n\nrealpw\nrealpw\n"
                                               (lambda () (read-luks-passphrase!)))))

;; ── 4. luksFormat：--batch-mode + --key-file=-，stdin 是 passphrase ──
(install-fake-cryptsetup 0)
(execute-luks-format "pw4fmt")
(test-assert "luksFormat 使用 --batch-mode 与 --key-file=-"
             (let ((args (fake-argv)))
               (and args
                    (string-contains args "--batch-mode")
                    (string-contains args "--key-file=-"))))
(test-assert "luksFormat stdin 收到 passphrase"
             (string=? "pw4fmt" (fake-stdin)))
;; 关键：display + EOF 不附加换行——最终用户启动时交互输入的
;; recovery password 必须与安装时写入的完全一致（含字节边界）。
(test-assert "luksFormat stdin 无尾随换行"
             (not (string-suffix? "\n" (fake-stdin))))

;; ── 5. open：--key-file=-，stdin 是 passphrase ─────────────
(execute-luks-open "pw4open")
(test-assert "open 使用 --key-file=-"
             (let ((args (fake-argv)))
               (and args (string-contains args "--key-file=-"))))
(test-assert "open stdin 收到 passphrase"
             (string=? "pw4open" (fake-stdin)))
(test-assert "open stdin 无尾随换行"
             (not (string-suffix? "\n" (fake-stdin))))

;; 非 ASCII passphrase：UTF-8 多字节字符经 stdin 原样传递
(execute-luks-format "秘密pw-✓")
(test-assert "非 ASCII passphrase 字节与 stdin 完全一致"
             (string=? "秘密pw-✓" (fake-stdin)))

;; ── 6. luksFormat 失败：抛错（不继续 open/Btrfs）────────────
(install-fake-cryptsetup 1)
(test-error "luksFormat 失败即抛错" #t
            (execute-luks-format "pw"))

;; ── 7. open 失败：抛错 ────────────────────────────────────
(test-error "open 失败即抛错" #t
            (execute-luks-open "pw"))

;; 恢复 PATH，避免影响后续测试文件。
(setenv "PATH" %original-path)
(unsetenv "FAKE_LUKS_ARGV")
(unsetenv "FAKE_LUKS_STDIN")
(unsetenv "FAKE_LUKS_EXIT")

(test-end)
