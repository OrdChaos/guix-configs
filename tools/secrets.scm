;;; age secrets CLI（docs/architecture/secrets.md）。master password 从终端 noecho
;;; 读取（read-secret-line），或 GUIXCFG_AGE_PASSPHRASE_FD 指定的 fd
;;; （测试/脚本化）；绝不出现在 argv/环境变量明文/log。
;;;
;;; 用法（仓库根下）：
;;;   guix time-machine -C channels.lock.scm -- repl -L modules -- \
;;;     tools/secrets.scm init
;;; 子命令：init | unlock | install | verify | lock | decrypt <cipher> <out>

(use-modules (guixcfg security age)
             (guixcfg storage install)   ; read-secret-line
             (ice-9 match)
             (ice-9 rdelim))

(define (repo-root)
  ;; 本文件在 <root>/tools/ 下。
  (dirname (dirname (canonicalize-path (car (command-line))))))

(define (read-passphrase confirm?)
  "从终端 noecho 读 master password（confirm? 时读两遍并校验一致）。
测试可用 GUIXCFG_AGE_PASSPHRASE_FD 指定的 fd（如 fd 3）注入（confirm
时 fd 里两行）。"
  (let ((fd-str (getenv "GUIXCFG_AGE_PASSPHRASE_FD")))
    (if (and fd-str (not (string-null? fd-str)))
      (let* ((port (fdopen (string->number fd-str) "r"))
             (a (read-line port)))
        (if confirm?
          (let ((b (read-line port)))
            (unless (string=? a b)
              (error "passphrases do not match"))
            a)
          a))
      (let ((a (read-secret-line "Master password: ")))
        (if confirm?
          (let ((b (read-secret-line "Confirm master password: ")))
            (unless (string=? a b)
              (error "passphrases do not match"))
            a)
          a)))))

(define (main args)
  (match (cdr args)
         (("init")
          (let ((recipient (age-init! (repo-root)
                                      (read-passphrase #t))))
            (format #t "stable recipient: ~a~%" recipient)
            (format #t "encrypted identity: ~a~%"
                    (string-append (repo-root) "/" %stable-identity-rel))
            (format #t "Back up your master password offline; the repository \
ciphertext alone cannot recover secrets without it.~%")))
         (("unlock")
          (let ((r (age-unlock! (repo-root) (read-passphrase #f))))
            (format #t "runtime identity ready at ~a (~a)~%"
                    (%runtime-identity-path) r)))
         (("install")
          (age-install! (repo-root))
          (format #t "identity installed to ~a~%" (%installed-identity-path)))
         (("verify")
          (age-verify! (repo-root))
          (format #t "installed identity matches repository recipient~%"))
         (("provision-password" user ciphertext)
          ;; explicit provisioning：解密 hash ciphertext → 校验 → 原子物化到
          ;; /persist/system/accounts/USER/password.hash（root 0700/0600）。
          (let ((path (provision-password-hash! user ciphertext)))
            (format #t "password hash materialized: ~a~%" path)))
         (("lock")
          (age-lock!)
          (format #t "runtime identity removed~%"))
         (("decrypt" cipher out)
          (age-decrypt-file cipher out 0 0 #o600)
          (format #t "decrypted ~a -> ~a~%" cipher out))
         (_
          (format (current-error-port)
                  "usage: secrets.scm init|unlock|install|verify|lock|decrypt CIPHER OUT|provision-password USER CIPHER~%")
          (exit 64))))

(main (command-line))
