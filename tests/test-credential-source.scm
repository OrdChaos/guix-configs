;;; LUKS passphrase 来源 resolver 测试（T1-T6，docs/operations/
;;; installation.md（--luks-secret））。
;;;
;;; 覆盖：来源互斥与 fail-closed 语义——
;;;   T1  'luks-secret 在 runtime 与 installed identity 都缺失时立即
;;;       报错（绝不回退交互）
;;;   T2  'interactive 返回 read-luks-passphrase!
;;;   T3  reader thunk 原样返回（noninteractive/测试注入通道）
;;;   T4  未知来源报错
;;;   T5  'luks-secret + identity 就位：reader 解密 luks-recovery.age
;;;       返回不带尾随换行的明文（真实 age 工具链）
;;;   T6  密文损坏：reader 调用抛错（不静默 fallback 到交互）
;;;   T7  'luks-secret 无 runtime 但有 installed identity（已装系统
;;;       场景）：同样解密成功——livecd 用 runtime，已装系统用
;;;       installed（/persist/system/keys/age/identity）
;;;
;;; 工具链（age/script）从 store 构建注入 PATH；runtime 路径与
;;; ciphertext 路径 parameterize 到临时目录（host 单测不写 repo）。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg security age)
             (guixcfg security credential-source)
             (guixcfg storage install)  ; read-luks-passphrase!
             (guixcfg utils process)     ; invoke-with-stdin
             (guix packages)
             (guix store)
             (guix derivations)
             (guix monads)
             (gnu packages golang-crypto) ; age
             (gnu packages linux)         ; util-linux（script）
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
  (let ((dir (mkdtemp "/tmp/guixcfg-cred-src-XXXXXX")))
    (dynamic-wind
     (lambda () #t)
     (lambda () (thunk dir))
     (lambda ()
       (false-if-exception (delete-file-recursively dir))))))

(define (with-resolver-paths thunk)
  "把 runtime identity、installed identity 与 luks-recovery ciphertext
路径 parameterize 到临时目录后运行 THUNK（它收到 root）。默认 installed
路径指向不存在的临时文件（hermetic：宿主 /persist 不参与判定）。"
  (with-temp-root
   (lambda (root)
     (parameterize ((%runtime-identity-dir (string-append root "/run-age"))
                    (%runtime-identity-path
                     (string-append root "/run-age/stable-identity"))
                    (%installed-identity-path
                     (string-append root "/persist/keys/age/identity"))
                    (%luks-recovery-secret-rel
                     (string-append root "/luks-recovery.age")))
                   (thunk root)))))

(define (encrypt-for-identity! root plaintext)
  "用仓库声明的 recipient 加密 PLAINTEXT 到 (%luks-recovery-secret-rel)。"
  (let ((recipient (string-trim-both
                    (call-with-input-file
                     (string-append root "/" %stable-recipient-rel)
                     (lambda (p) (read-string p))))))
    (invoke-with-stdin (string-append plaintext "\n") "age" "--armor"
                       "-r" recipient "-o" (%luks-recovery-secret-rel))))

(test-begin "credential-source")

;; Guile error 异常形态随模块执行方式变化（解释 vs 编译 thunk，
;; 实测 2026-08）：(#f "~A" (MSG) #f) 或 (#f MSG () #f)——
;; 断言必须两者兼容（同 test-tpm2-enroll 的 misc-error-message）。
(define (misc-error-message a)
  (let ((irritants (caddr a)))
    (if (and (pair? irritants) (string? (car irritants)))
      (car irritants)
      (cadr a))))

;; ── T1：'luks-secret 无任何 identity → fail-closed ─────────
(with-resolver-paths
 (lambda (root)
   (test-assert "T1: luks-secret without runtime AND installed identity errors"
                (catch #t
                  (lambda () (resolve-luks-passphrase-source 'luks-secret) #f)
                  (lambda (k . a)
                    (and (eq? k 'misc-error)
                         (string-contains (misc-error-message a)
                                          "no stable identity")))))))

;; ── T2：'interactive → read-luks-passphrase! ────────────────
(test-assert "T2: interactive resolves to read-luks-passphrase!"
             (eq? (resolve-luks-passphrase-source 'interactive)
                  read-luks-passphrase!))

;; ── T3：reader thunk 原样返回 ───────────────────────────────
(let ((injected (lambda () "injected-pw")))
  (test-assert "T3: injected reader returned unchanged"
               (eq? (resolve-luks-passphrase-source injected) injected)))

;; ── T4：未知来源报错 ────────────────────────────────────────
(test-assert "T4: unknown source errors"
             (catch #t
               (lambda () (resolve-luks-passphrase-source 'bogus) #f)
               (lambda (k . a) #t)))

;; ── T5：'luks-secret + identity → 解密 luks-recovery.age ────
(with-resolver-paths
 (lambda (root)
   (age-init! root %test-pass)
   (age-unlock! root %test-pass)
   (let ((plain "test-luks-recovery-pass-7x9"))
     (encrypt-for-identity! root plain)
     (let ((reader (resolve-luks-passphrase-source 'luks-secret)))
       (test-equal "T5: reader returns decrypted LUKS plaintext (no trailing newline)"
                   plain (reader))
       (test-equal "T5: repeated calls return the same plaintext"
                   plain (reader))))))

;; ── T6：密文损坏 → reader 调用抛错，不 fallback 到交互 ─────
(with-resolver-paths
 (lambda (root)
   (age-init! root %test-pass)
   (age-unlock! root %test-pass)
   (call-with-output-file (%luks-recovery-secret-rel)
                          (lambda (p) (display "not-an-age-ciphertext" p)))
   (let ((reader (resolve-luks-passphrase-source 'luks-secret)))
     (test-assert "T6: corrupt ciphertext makes reader call throw (no interactive fallback)"
                  (catch #t
                    (lambda () (reader) #f)
                    (lambda (k . a) #t))))))

;; ── T7：无 runtime、有 installed identity（已装系统）→ 解密 ──
(with-temp-root
 (lambda (root)
   (let* ((run (string-append root "/run-age"))
          (installed-dir (string-append root "/persist/system/keys/age"))
          (installed (string-append installed-dir "/identity")))
     ;; init + unlock 后经 age-install! 物化 installed identity
     ;; （真实 API：含 recipient 校验与 0700/0600 权限）。
     (parameterize ((%runtime-identity-dir run)
                    (%runtime-identity-path
                     (string-append run "/stable-identity"))
                    (%installed-identity-dir installed-dir)
                    (%installed-identity-path installed)
                    (%luks-recovery-secret-rel
                     (string-append root "/luks-recovery.age")))
       (age-init! root %test-pass)
       (age-unlock! root %test-pass)
       ;; age-install! 的 /persist 可用性 guard = dirname(dirname(...)) =
       ;; <root>/persist/system（LUKS-backed persist 根）。
       (mkdir (string-append root "/persist"))
       (mkdir (string-append root "/persist/system"))
       (age-install! root)
       (let ((plain "installed-identity-luks-pw-42"))
         (encrypt-for-identity! root plain)
         ;; 模拟已装系统：runtime 目录不存在，只有 installed identity。
         (parameterize ((%runtime-identity-dir (string-append root "/no-run"))
                        (%runtime-identity-path
                         (string-append root "/no-run/stable-identity"))
                        (%installed-identity-dir installed-dir)
                        (%installed-identity-path installed)
                        (%luks-recovery-secret-rel
                         (string-append root "/luks-recovery.age")))
           (let ((reader (resolve-luks-passphrase-source 'luks-secret)))
             (test-equal "T7: installed identity fallback decrypts luks-recovery.age"
                         plain (reader)))))))))

(test-end "credential-source")
