;;; LUKS passphrase 来源的 canonical resolver（disk-install 与
;;; tpm2-enroll 共享，docs/operations/installation.md（--luks-secret））。
;;;
;;; 不变量：
;;;   - 只有一个规范实现：'luks-secret 的来源、ciphertext 路径、runtime
;;;     identity 前置检查都在这里，任何工具不得复制实现（second
;;;     implementation 一律改为调用本模块）；
;;;   - 来源互斥：'interactive / 'luks-secret / reader thunk 三选一，
;;;     由 CLI 解析层保证，本模块对未知来源 fail closed；
;;;   - 'luks-secret 在 runtime 与 installed identity 都缺失时立即失败
;;;     ——绝不静默回退到交互输入；解密失败同样在调用处抛错（TPM
;;;     mutation 之前）。两个 identity 任一个可用即可：livecd 安装期
;;;     用 runtime（需先 secrets unlock）；已装系统用 installed
;;;     （/persist/system/keys/age/identity，无需 unlock）；
;;;   - plaintext passphrase 只存在于进程内存与 /run 0600 中转文件，
;;;     不进 argv/environment/log/store（docs/architecture/secrets.md）。

(define-module (guixcfg security credential-source)
               #:use-module (guixcfg security age)        ; make-age-secret-reader
               #:use-module (guixcfg storage install)     ; read-luks-passphrase!
               #:use-module (ice-9 match)
               #:export (%luks-recovery-secret-rel
                         resolve-luks-passphrase-source))

;; 仓库内相对路径（repo 根为 cwd；disk-install / tpm2-enroll 都从
;; repo 根运行）。age-encrypted LUKS recovery secret，--luks-secret
;; 的 canonical 数据源。parameter 供测试覆盖（host 单测不写 repo）。
(define %luks-recovery-secret-rel
  (make-parameter "modules/guixcfg/security/secrets/luks-recovery.age"))

(define (resolve-luks-passphrase-source source)
  "SOURCE 是互斥的 LUKS passphrase 来源之一：
    'luks-secret  → 用 stable S 解密 %LUKS-RECOVERY-SECRET-REL（需先
                    secrets unlock；identity 缺失立即报错，绝不回退）。
    'interactive  → read-luks-passphrase!（两次输入确认，安装期用）。
    reader thunk → 原样返回（tpm2-enroll 的交互 / --noninteractive /
                    测试注入；失败语义由调用方定义）。
  返回 reader thunk：调用一次得到不带尾随换行的 passphrase。
  plaintext 只存在于进程内存与 /run 0600 中转文件（age.scm），
  不进 argv/env/log/store。"
  (cond
    ((eq? source 'luks-secret)
     ;; fail-closed：两个 identity 都缺失时在进入任何 TPM/LUKS
     ;; mutation 前失败。livecd（安装/替换）→ runtime S（secrets
     ;; unlock）；已装系统 → installed S（/persist，日常可用）。
     (unless (or (runtime-identity-present?)
                 (file-exists? (%installed-identity-path)))
       (error "no stable identity (runtime or installed); run 'secrets unlock' first (livecd) or verify /persist/system/keys/age/identity"))
     (make-age-secret-reader (%luks-recovery-secret-rel)))
    ((eq? source 'interactive)
     read-luks-passphrase!)
    ((procedure? source)
     source)
    (else
     (error "unknown LUKS passphrase source" source))))
