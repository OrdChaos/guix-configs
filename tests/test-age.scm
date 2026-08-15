;;; age stable identity 测试（S1-S6 覆盖 + roundtrip + 幂等）。
;;; 工具链（age/age-keygen/script）从 store 构建注入 PATH；
;;; runtime/installed 路径 parameterize 到临时目录（host 单测无 /run
;;; 与 /persist 写权限）。master password 用测试约定值。

(use-modules (guixcfg security age)
             (guixcfg utils process)     ; invoke-with-stdin
             (guix packages)
             (guix store)
             (guix derivations)
             (guix monads)
             (gnu packages golang-crypto) ; age
             (gnu packages linux)         ; util-linux（script）
             (ice-9 ftw)
             (ice-9 rdelim)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %store (open-connection))

(define (store-bin pkg)
  (string-append
   (derivation->output-path
    (run-with-store %store (package->derivation pkg)))
   "/bin"))

;; age（encrypt/decrypt/keygen）+ util-linux（script 伪终端）
(build-derivations %store
                   (list (run-with-store %store
                           (package->derivation age))
                         (run-with-store %store
                           (package->derivation util-linux))))
(setenv "PATH"
        (string-append (store-bin age) ":" (store-bin util-linux) ":"
                       (getenv "PATH")))

(define %test-pass "guix-vm")

(define (with-temp-root thunk)
  (let ((dir (mkdtemp "/tmp/guixcfg-age-test-XXXXXX")))
    (dynamic-wind
      (lambda () #t)
      (lambda () (thunk dir))
      (lambda ()
        (false-if-exception (delete-file-recursively dir))))))

(define (with-test-paths thunk)
  "把 runtime/installed 路径 parameterize 到临时目录后运行 THUNK（
它收到 (root . runtime-dir)）。"
  (with-temp-root
   (lambda (root)
     (parameterize ((%runtime-identity-dir (string-append root "/run-age"))
                    (%runtime-identity-path
                     (string-append root "/run-age/stable-identity"))
                    (%installed-identity-dir
                     (string-append root "/persist/keys/age"))
                    (%installed-identity-path
                     (string-append root "/persist/keys/age/identity")))
       (mkdir-p (string-append root "/persist/system"))
       (thunk root)))))

(define (mode-of path)
  (logand (stat:mode (stat path)) #o777))

(test-begin "age")

;; ── init + roundtrip ──────────────────────────────────────────
(with-test-paths
 (lambda (root)
   (let ((recipient (age-init! root %test-pass)))
     (test-assert "init returns valid recipient"
       (recipient-format? recipient))
     (test-assert "recipient file written with 0644"
       (= #o644 (mode-of (string-append root "/" %stable-recipient-rel))))
     (test-assert "encrypted identity written with 0644"
       (= #o644 (mode-of (string-append root "/" %stable-identity-rel))))
     (test-assert "recipient file matches derived"
       (string=? (string-trim-both
                  (call-with-input-file
                      (string-append root "/" %stable-recipient-rel)
                    (lambda (p) (read-string p))))
                 recipient))

     ;; 拒绝覆盖
     (test-assert "init refuses to overwrite"
       (catch #t
         (lambda () (age-init! root %test-pass) #f)
         (lambda (k . a) #t)))

     ;; unlock（正确密码）→ runtime S
     (test-equal "unlock succeeds" 'unlocked
       (age-unlock! root %test-pass))
     (test-assert "runtime identity 0600"
       (= #o600 (mode-of (%runtime-identity-path))))
     (test-assert "runtime dir 0700"
       (= #o700 (mode-of (%runtime-identity-dir))))
     (test-equal "unlock is idempotent (no re-prompt)"
       'already-unlocked (age-unlock! root %test-pass))

     ;; install + verify
     ;; installed dir 固定检查 /persist/system——测试 root 下已建该目录
     (test-assert "install succeeds"
       (begin (age-install! root) #t))
     (test-assert "installed identity 0600"
       (= #o600 (mode-of (%installed-identity-path))))
     (test-assert "installed dir 0700"
       (= #o700 (mode-of (%installed-identity-dir))))
     (test-assert "verify passes" (age-verify! root))

     ;; age-decrypt-file roundtrip（sentinel）
     (let* ((sentinel "GUIXCFG_SECRET_SENTINEL_test-roundtrip-7f3a")
            (plain (string-append root "/plain.txt"))
            (cipher (string-append root "/secret.age"))
            (out (string-append root "/out.txt")))
       (call-with-output-file plain
         (lambda (p) (display sentinel p)))
       ;; 用 S 的 recipient 加密（identity 模式，不需要 passphrase）
       (let ((recipient (string-trim-both
                         (call-with-input-file
                             (string-append root "/" %stable-recipient-rel)
                           (lambda (p) (read-string p))))))
         (invoke-with-stdin
          sentinel "age" "--armor" "-r" recipient "-o" cipher))
       (test-assert "decrypt roundtrip content"
         (begin
           (age-decrypt-file cipher out (getuid) (getgid) #o400)
           (string=? sentinel
                     (string-trim-both
                      (call-with-input-file out
                        (lambda (p) (read-string p)))))))
       (test-assert "decrypt output mode 0400"
         (= #o400 (mode-of out)))

       ;; S4：损坏 ciphertext → 失败且不留 partial plaintext
       (call-with-output-file cipher
         (lambda (p) (display "AGE-ENCRYPTED-CORRUPTED" p)))
       (let ((out2 (string-append root "/out2.txt")))
         (test-assert "corrupt ciphertext fails closed"
           (catch #t
             (lambda () (age-decrypt-file cipher out2 (getuid) (getgid) #o400) #f)
             (lambda (k . a) #t)))
         (test-assert "no partial plaintext left"
           (not (file-exists? out2)))
         (test-assert "no .new residue left"
           (not (file-exists? (string-append out2 ".new")))))))))

;; ── S1：错误 master password ──────────────────────────────────
(with-test-paths
 (lambda (root)
   (age-init! root %test-pass)
   (let ((enc-before
          (call-with-input-file
              (string-append root "/" %stable-identity-rel)
            (lambda (p) (read-string p)))))
     (test-assert "wrong passphrase fails"
       (catch #t
         (lambda () (age-unlock! root "wrong-password") #f)
         (lambda (k . a) #t)))
     (test-assert "no runtime identity after wrong passphrase"
       (not (runtime-identity-present?)))
     (test-assert "repository ciphertext unchanged"
       (string=? enc-before
                 (call-with-input-file
                     (string-append root "/" %stable-identity-rel)
                   (lambda (p) (read-string p))))))))

;; ── S2：损坏的 encrypted identity ─────────────────────────────
(with-test-paths
 (lambda (root)
   (age-init! root %test-pass)
   (call-with-output-file
       (string-append root "/" %stable-identity-rel)
     (lambda (p) (display "NOT-AGE-CIPHERTEXT" p)))
   (test-assert "corrupt encrypted identity fails closed"
     (catch #t
       (lambda () (age-unlock! root %test-pass) #f)
       (lambda (k . a) #t)))))

;; ── S3：installed identity recipient mismatch → fail closed ───
(with-test-paths
 (lambda (root)
   (age-init! root %test-pass)
   (age-unlock! root %test-pass)
   (age-install! root)
   ;; 换成另一个 identity（另一个 S）
   (let ((other (invoke-capture "age-keygen")))
     (call-with-output-file (%installed-identity-path)
       (lambda (p) (display other p))))
   (test-assert "recipient mismatch fails closed"
     (catch #t
       (lambda () (age-verify! root) #f)
       (lambda (k . a) #t)))))

;; ── unlock 缺密文 → 明确失败 ─────────────────────────────────
(with-test-paths
 (lambda (root)
   (test-assert "missing encrypted identity fails"
     (catch #t
       (lambda () (age-unlock! root %test-pass) #f)
       (lambda (k . a) #t)))))

(test-end "age")
