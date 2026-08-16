;;; age stable identity 核心逻辑（docs/secrets.md）。
;;;
;;; 威胁模型与不变量：
;;;   - 一个个人 trust domain 只有一个长期稳定的 age identity S；
;;;     仓库里只有 recipient S（公钥）与 passphrase 加密的 S（ciphertext
;;;     可进 Git），明文 S 只在 /run（临时）与 LUKS 内的
;;;     /persist/system/keys/age/identity（安装后）；
;;;   - 不做 per-machine recipient；换机器恢复同一个 S，不 rekey；
;;;   - master password 绝不进仓库/store/磁盘——unlock 时经 script 伪
;;;     终端的 stdin 转交给 age（age 从 /dev/tty 读密语；script 提供
;;;     controlling tty），不进 argv/environment/log。

(define-module (guixcfg security age)
               #:use-module (guix build utils)          ; mkdir-p
               #:use-module (guixcfg utils process)      ; invoke-*（stdin 注入）
               #:use-module (guixcfg utils atomic-file)  ; 原子写
               #:use-module (ice-9 regex)
               #:use-module (ice-9 rdelim)
               #:use-module (srfi srfi-13)
               #:export (%runtime-identity-dir
                         %runtime-identity-path
                         %installed-identity-dir
                         %installed-identity-path
                         %stable-recipient-rel
                         %stable-identity-rel
                         recipient-format?
                         runtime-identity-present?
                         current-identity-path
                         age-init!
                         age-unlock!
                         age-install!
                         age-verify!
                         age-lock!
                         age-decrypt-file
                         age-decrypt-to-string
                         make-age-secret-reader
                         %account-credentials-dir
                         provision-password-hash!
                         password-hash-format?))

;; 运行时临时 S（tmpfs；目录 0700、文件 0600）与安装后的
;; authoritative S（LUKS-backed persist）的默认路径；函数经 parameter
;; 读取，测试可 parameterize 覆盖（host 单测无 /run 写权限）。
(define %runtime-identity-dir
  ;; CLI 可用 GUIXCFG_RUNTIME_DIR 覆盖（开发机/测试无 /run 写权限）。
  (make-parameter (or (getenv "GUIXCFG_RUNTIME_DIR") "/run/guixcfg-age")))
(define %runtime-identity-path
  (make-parameter (string-append (%runtime-identity-dir)
                                 "/stable-identity")))
(define %installed-identity-dir
  (make-parameter "/persist/system/keys/age"))
(define %installed-identity-path
  (make-parameter (string-append (%installed-identity-dir) "/identity")))

;; 仓库内相对路径（以 repo 根为基准；工具/测试传 root 参数）。
(define %stable-recipient-rel "secrets/recipients/stable.agepub")
(define %stable-identity-rel "secrets/bootstrap/stable-identity.age")

(define (recipient-format? s)
  "S 是否符合 age1... 公钥 recipient 形态（bech32）。"
  (and (string? s)
       (string-match "^age1[02-9ac-hj-np-z]+$" (string-trim-both s))
       #t))

(define (runtime-identity-present?)
  "运行时临时 S 是否已就位。"
  (file-exists? (%runtime-identity-path)))

(define (current-identity-path)
  "当前可用的 identity 路径：安装/bootstrap 期 runtime 临时 S 优先
（此时 /persist 尚未就绪）；日常运行用 LUKS 内 installed S。"
  (if (runtime-identity-present?)
      (%runtime-identity-path)
      (%installed-identity-path)))

(define (read-file-string path)
  (call-with-input-file path
    (lambda (port) (read-string port))))

(define (secret-file! path contents mode)
  "把 CONTENTS（字符串）原子写入 PATH，权限 MODE；父目录 fsync。"
  (atomic-write-file! path
                      (lambda (port) (display contents port)))
  (chmod path mode))

(define (fresh-run-temp name)
  "在 runtime 目录建一个 0600 空临时文件，返回路径（调用方负责删除）。"
  (mkdir-p (%runtime-identity-dir))
  (chmod (%runtime-identity-dir) #o700)
  (let ((p (string-append (%runtime-identity-dir) "/" name)))
    (call-with-output-file p (lambda (port) #t))
    (chmod p #o600)
    p))

;;; ────────────────────────────────────────────────────────────
;;; age 进程调用约定：
;;;   - passphrase 模式：age 只从 /dev/tty 读密语——用 script 伪终端
;;;     （script -qec 'age ...' /dev/null）提供 controlling tty，密语经
;;;     script 的 stdin 转发（加密需两遍确认，解密一遍）。密语不进
;;;     argv（argv 里只有固定参数与公开路径）。
;;;   - identity 模式（-i）：无需 tty——stdin 直接关闭即可。

(define (age-pty-run passphrase-lines age-command)
  "以 script 伪终端运行 AGE-COMMAND（shell 命令字符串，固定参数+
公开路径），PASSPHRASE-LINES 为写入 script stdin 的密语行（加密两
遍、解密一遍）。--echo=never 关闭转发回显——否则密语在 age 启动/
关 echo 前的瞬间会被伪终端回显到输出。非零退出码抛错（age 失败不
留 partial 输出文件）。"
  (invoke-with-stdin passphrase-lines "script" "-qec" age-command
                     "--echo=never" "/dev/null"))

(define (age-encrypt-passphrase! plaintext-path out-path passphrase)
  "passphrase 加密 PLAINTEXT-PATH → OUT-PATH（armor）。plaintext 与
输出都是 /run 0600 文件（调用方保证路径在 tmpfs）。"
  (age-pty-run (string-append passphrase "\n" passphrase "\n")
               (string-append
                "age --passphrase --armor -o " out-path " "
                plaintext-path)))

(define (age-decrypt-passphrase ciphertext-path passphrase)
  "passphrase 解密 CIPHERTEXT-PATH，返回明文字符串（经 /run 0600
临时文件，读回即删）。"
  (let ((tmp (fresh-run-temp ".decrypt-out")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (age-pty-run (string-append passphrase "\n")
                     (string-append "age --decrypt -o " tmp " "
                                    ciphertext-path))
        (read-file-string tmp))
      (lambda ()
        (false-if-exception (delete-file tmp))))))

(define (derive-recipient identity-contents)
  "从 identity 内容（AGE-SECRET-KEY-...）推导 recipient；identity 经
/run 0600 临时文件传入 age-keygen -y，不进 argv。"
  (let ((tmp (fresh-run-temp ".derive-in")))
    (dynamic-wind
      (lambda ()
        (call-with-output-file tmp
          (lambda (port) (display identity-contents port))))
      (lambda ()
        (string-trim-both (invoke-capture "age-keygen" "-y" tmp)))
      (lambda ()
        (false-if-exception (delete-file tmp))))))

;;; ────────────────────────────────────────────────────────────
;;; lifecycle

(define (age-init! root passphrase)
  "首次生成 stable identity S：公钥写 ROOT/secrets/recipients/
stable.agepub；PASSPHRASE 加密的私钥写 ROOT/secrets/bootstrap/
stable-identity.age。默认拒绝覆盖已有 identity。明文 S 只在内存与
/run 0600 临时文件间存在。返回公钥 recipient。"
  (let ((pub-file (string-append root "/" %stable-recipient-rel))
        (enc-file (string-append root "/" %stable-identity-rel)))
    (when (or (file-exists? pub-file) (file-exists? enc-file))
      (error "stable identity already exists; refusing to overwrite"
             pub-file enc-file))
    (let* ((identity (invoke-capture "age-keygen"))
           (recipient (derive-recipient identity)))
      (unless (recipient-format? recipient)
        (error "derived recipient has unexpected format" recipient))
      ;; plaintext identity 落 /run 0600 临时文件供 age 读取，加密后删。
      (let ((plain-tmp (fresh-run-temp ".init-plain"))
            (enc-tmp (fresh-run-temp ".init-enc")))
        (dynamic-wind
          (lambda ()
            (call-with-output-file plain-tmp
              (lambda (port) (display identity port))))
          (lambda ()
            (age-encrypt-passphrase! plain-tmp enc-tmp passphrase)
            (let ((ciphertext (read-file-string enc-tmp)))
              (mkdir-p (dirname pub-file))
              (mkdir-p (dirname enc-file))
              ;; 顺序：先 ciphertext 后公钥——失败时不留“有公钥无私钥”。
              (secret-file! enc-file ciphertext #o644)
              (secret-file! pub-file (string-append recipient "\n") #o644)))
          (lambda ()
            (false-if-exception (delete-file plain-tmp))
            (false-if-exception (delete-file enc-tmp)))))
      recipient)))

(define (age-unlock! root passphrase)
  "用 PASSPHRASE 解密 ROOT 下的 encrypted stable identity，明文写
/run/guixcfg-age/stable-identity（0600，目录 0700，tmpfs）。已是当前
S（recipient 匹配）时直接复用，不重复索要密码。返回符号：
already-unlocked（复用）或 unlocked（新解密）。"
  (define enc-file (string-append root "/" %stable-identity-rel))
  (define pub-file (string-append root "/" %stable-recipient-rel))
  ;; 幂等：已有临时 S 且与仓库声明匹配 → 直接复用。
  (if (and (runtime-identity-present?)
           (file-exists? pub-file)
           (string=? (string-trim-both (read-file-string pub-file))
                     (derive-recipient
                      (read-file-string (%runtime-identity-path)))))
      'already-unlocked
      (begin
        (unless (file-exists? enc-file)
          (error "encrypted stable identity missing" enc-file))
        (let* ((decrypted (age-decrypt-passphrase enc-file passphrase))
               (recipient (derive-recipient decrypted)))
          ;; 错密码在 age 层已失败；这里再校验 recipient——fail closed。
          (unless (and (file-exists? pub-file)
                       (string=? (string-trim-both (read-file-string pub-file))
                                 recipient))
            (error "unlocked identity recipient does not match repository"
                   recipient))
          (mkdir-p (%runtime-identity-dir))
          (chmod (%runtime-identity-dir) #o700)
          (secret-file! (%runtime-identity-path) decrypted #o600)
          'unlocked))))

(define (age-lock!)
  "删除运行时临时 S（安装完成后调用）。"
  (false-if-exception (delete-file (%runtime-identity-path)))
  #t)

(define (age-install! root)
  "把运行时临时 S 安装为机器的 authoritative identity：
/persist/system/keys/age/identity（root:root，目录 0700、文件 0600）。
仅在 LUKS-backed /persist 已可用时调用（安装流程在 LUKS 建立后）。
安装前强制 recipient 校验——与仓库声明不一致则 fail closed。"
  (unless (runtime-identity-present?)
    (error "no runtime identity; unlock first"))
  ;; /persist/system 存在性检查（参数化后 = installed-dir 的祖父目录）。
  (unless (file-exists? (dirname (dirname (%installed-identity-dir))))
    (error "/persist not available; LUKS must be unlocked first"))
  (let* ((contents (read-file-string (%runtime-identity-path)))
         (recipient (derive-recipient contents))
         (expected (string-trim-both
                    (read-file-string
                     (string-append root "/" %stable-recipient-rel)))))
    (unless (string=? recipient expected)
      (error "runtime identity recipient mismatch; refusing to install"
             recipient expected))
    (mkdir-p (%installed-identity-dir))
    (chmod (%installed-identity-dir) #o700)
    (secret-file! (%installed-identity-path) contents #o600)
    #t))

(define (age-verify! root)
  "验证 installed identity 推导的 recipient 与仓库声明完全一致；
不一致抛错（fail closed），绝不采用机器上的其它 identity。
返回 #t（一致）。"
  (unless (file-exists? (%installed-identity-path))
    (error "installed identity missing" (%installed-identity-path)))
  (let ((recipient (derive-recipient
                    (read-file-string (%installed-identity-path))))
        (expected (string-trim-both
                   (read-file-string
                    (string-append root "/" %stable-recipient-rel)))))
    (unless (string=? recipient expected)
      (error "installed identity recipient mismatch" recipient expected))
    #t))

(define (age-decrypt-file ciphertext-path out-path owner-uid owner-gid mode)
  "用 installed S 解密 CIPHERTEXT-PATH（整文件 age）到 OUT-PATH
（runtime 目标），随后设置 owner/mode。明文输出先到同目录 .new
临时文件（0600）再原子 rename——age 失败（错 identity/损坏密文）
时 age 不写输出文件，不留 partial plaintext。返回 #t。"
  (let ((tmp (string-append out-path ".new")))
    (mkdir-p (dirname out-path))
    (dynamic-wind
      (lambda ()
        (call-with-output-file tmp (lambda (port) #t))
        (chmod tmp #o600))
      (lambda ()
        ;; identity 经 -i 文件参数（路径无 secret 内容）；明文经 -o 文件。
        (invoke-with-stdin "" "age" "--decrypt"
                           "-i" (current-identity-path)
                           "-o" tmp ciphertext-path)
        (chmod tmp mode)
        (chown tmp owner-uid owner-gid)
        (rename-file tmp out-path))
      (lambda ()
        (false-if-exception (delete-file tmp))))
    #t))

(define (age-decrypt-to-string ciphertext-path)
  "用 installed S 解密 CIPHERTEXT-PATH，明文作为字符串返回（只在
本进程内存；经 /run 0600 临时文件中转，读回即删）。"
  (let ((tmp (string-append (%runtime-identity-dir) "/.dec-str-"
                            (number->string (getpid)))))
    (mkdir-p (%runtime-identity-dir))
    (chmod (%runtime-identity-dir) #o700)
    (dynamic-wind
      (lambda ()
        (call-with-output-file tmp (lambda (port) #t))
        (chmod tmp #o600))
      (lambda ()
        (invoke-with-stdin "" "age" "--decrypt"
                           "-i" (current-identity-path)
                           "-o" tmp ciphertext-path)
        (read-file-string tmp))
      (lambda ()
        (false-if-exception (delete-file tmp))))))

(define (make-age-secret-reader ciphertext-path)
  "返回一个 reader thunk：首次调用解密 CIPHERTEXT-PATH（installed S）
并返回明文（去掉尾部换行），供 install.scm 的 passphrase-reader
使用——与交互读取同一 stdin 语义，明文不落盘、不进 argv/env。"
  (lambda ()
    (string-trim-right (age-decrypt-to-string ciphertext-path)
                       #\newline)))

;;; ────────────────────────────────────────────────────────────
;;; 账户凭据的持久物化（三层模型：repo ciphertext → persistent
;;; authoritative credential → ephemeral /etc/shadow 投影；
;;; docs/secrets.md 第 15.5 节）。

;; /persist/system/accounts/<user>/password.hash（root 0700/0600）；
;; parameter 化供测试覆盖。
(define %account-credentials-dir
  ;; 安装期（LiveCD）写 /mnt/persist/...：GUIXCFG_ACCOUNTS_DIR 覆盖。
  (make-parameter (or (getenv "GUIXCFG_ACCOUNTS_DIR")
                      "/persist/system/accounts")))

(define (password-hash-format? s)
  "S 是否是 shadow 兼容的 crypt hash（$id$salt$hash，非空、无换行/
  冒号注入）。"
  (and (string? s)
       (string-match "^\\$[0-9a-z]+\\$[^:$]+\\$[^: \n]+$" s)
       #t))

(define (provision-password-hash! user ciphertext-path)
  "explicit provisioning（fresh install / 密码更新）：解密
  CIPHERTEXT-PATH（user-password.hash.age）→ 校验 hash 形态 → 原子
  物化到 /persist/system/accounts/USER/password.hash（root 0700/0600）。
  只保存 hash；失败不留半个文件。返回目标路径。"
  (let* ((hash (string-trim-right
                (age-decrypt-to-string ciphertext-path) #\newline)))
    (unless (password-hash-format? hash)
      (error "provisioned password material is not a valid shadow hash"
             user))
    (let ((dir (string-append (%account-credentials-dir) "/" user)))
      (mkdir-p (%account-credentials-dir))
      (chmod (%account-credentials-dir) #o700)
      ;; root-only chown：安装流程以 root 运行；普通用户单测环境
      ;; （无 CAP_CHOWN）跳过。
      (false-if-exception (chown (%account-credentials-dir) 0 0))
      (mkdir-p dir)
      (chmod dir #o700)
      (false-if-exception (chown dir 0 0))
      (secret-file! (string-append dir "/password.hash")
                    (string-append hash "\n") #o600)
      (false-if-exception (chown (string-append dir "/password.hash") 0 0))
      (string-append dir "/password.hash"))))
