;;; tpm2-tools 适配层：本仓库唯一知道 tpm2-tools CLI 的模块
;;; （docs/boot.md 第 16.4 节）。PCR7-only 版本：只保留 PolicyPCR
;;; 机制，不包含 PolicyAuthorize / PCR11 内容。
;;;
;;; 所有命令语义以【实测】为准（2026-08，tpm2-tools 5.7 + swtpm）：
;;;   - tpm2_policypcr 指定期望值用 -f <pcrread 原始输出> + -l <list>；
;;;     -l "bank:index=值" 前向封印语法在 swtpm TCTI 下报 0x1C4；
;;;   - tpm2_create -L <文件> 在 swtpm TCTI 下报 0x902，-L <hex> 正常；
;;;   - tcti-swtpm 无 resource manager：transient object slot 会耗尽
;;;     （每个命令的 ContextLoad 占新 slot），命令后要显式
;;;     tpm2_flushcontext -t；生产环境走 /dev/tpmrm0（内核 RM）无此问题；
;;;   - TPM2TOOLS_AUTOFLUSH=yes 会把命令创建的 session 一起 flush
;;;     （0x70018），破坏跨命令 trial/policy session 流程，因此测试
;;;     环境用 scoped flushcontext -t，不用 AUTOFLUSH。
;;;
;;; TCTI 约定：全部函数接受 #:tcti 关键字（如 "device:/dev/tpmrm0"
;;; 或 "swtpm:path=..."），通过 TPM2TOOLS_TCTI 环境变量传给子进程。
;;;
;;; 本模块不实现任何 TPM 算法：PolicyPCR 摘要、sealed object、unseal
;;; 全部由 tpm2-tools 完成；Scheme 只编排。

(define-module (guixcfg security tpm2 tpm2-tools)
               #:use-module (guix build utils)        ; invoke
               #:use-module (guixcfg utils process)   ; invoke-with-stdin、invoke-capture
               #:use-module (guix records)            ; define-record-type*
               #:use-module (rnrs bytevectors)        ; bytevector->u8-list
               #:use-module (ice-9 binary-ports)      ; get-bytevector-all
               #:use-module (ice-9 popen)             ; open-pipe*
               #:use-module (srfi srfi-1)             ; append-map
               #:export (;; 环境（production / test 显式区分）
                         <tpm2-environment>
                         tpm2-environment make-tpm2-environment
                         tpm2-environment?
                         tpm2-environment-tcti
                         tpm2-environment-cleanup
                         current-tpm2-environment
                         make-test-tpm2-environment
                         ;; 低层原语（按 tpm2-tools 命令一对一）
                         tpm2-createprimary!
                         tpm2-policy-pcr-digest!
                         tpm2-create-sealed!
                         tpm2-load-sealed!
                         tpm2-policy-pcr-session!
                         tpm2-unseal!
                         tpm2-pcrread!
                         tpm2-pcrextend!
                         tpm2-flush-transients!
                         tpm2-start-policy-session!
                         tpm2-flush-session!
                         ;; 辅助
                         hex->bytes
                         bytes->hex))

;;; ────────────────────────────────────────────────────────────
;;; TPM 环境
;;;
;;;   cleanup = 'none       生产：/dev/tpmrm0 内核 resource manager
;;;                          负责 transient 回收；不做任何全局 flush。
;;;   cleanup = 'transient  测试：direct swtpm TCTI 无 RM；每个命令后
;;;                          只 flush TRANSIENT OBJECTS（-t，不碰
;;;                          sessions——实测 TPM2TOOLS_AUTOFLUSH=yes
;;;                          会把本命令创建的 session 一起 flush，
;;;                          破坏跨命令 trial/policy session 流程，
;;;                          0x70018；因此测试环境用 -t scoped 清理）。
;;; 上层 enrollment/initrd 函数不感知 cleanup 细节（测试环境逻辑
;;; 集中在 adapter）。

(define-record-type* <tpm2-environment>
                     tpm2-environment make-tpm2-environment
                     tpm2-environment?
                     (tcti    tpm2-environment-tcti)
                     (cleanup tpm2-environment-cleanup
                              (default 'none)))

(define %production-tpm2-environment
  (tpm2-environment (tcti "device:/dev/tpmrm0")))

(define current-tpm2-environment
  (make-parameter %production-tpm2-environment))

(define* (make-test-tpm2-environment tcti)
         "direct swtpm TCTI 测试环境：每命令后 scoped flush transient objects。"
         (tpm2-environment (tcti tcti) (cleanup 'transient)))

(define (with-tcti tcti thunk)
  "在 TCTI 环境变量下执行 THUNK 并恢复原值。"
  (let ((old (getenv "TPM2TOOLS_TCTI")))
    (dynamic-wind
     (lambda () (setenv "TPM2TOOLS_TCTI" tcti))
     thunk
     (lambda ()
       (if old (setenv "TPM2TOOLS_TCTI" old)
         (unsetenv "TPM2TOOLS_TCTI"))))))

(define (tpm2-run-raw tcti . args)
  "以指定 TCTI 运行 tpm2-tools 命令；非零退出码抛错。不自动 flush。"
  (with-tcti tcti
             (lambda ()
               (apply invoke (car args) (cdr args)))))

(define (tpm2-run tcti . args)
  "以指定 TCTI 运行 tpm2-tools 命令；非零退出码抛错。
transient 回收语义由 (current-tpm2-environment) 决定：
  - cleanup 'none（生产）：不做任何全局 flush——/dev/tpmrm0 内核
    RM 负责回收；显式全局 flush 会误伤其他进程的对象；
  - cleanup 'transient（测试）：命令后 tpm2_flushcontext -t
    （仅 transient objects，不碰 sessions——AUTOFLUSH=yes 实测会
    杀 session，0x70018）。
本 operation 显式创建的 session 由调用方 scoped cleanup
（tpm2-flush-session! / dynamic-wind）。"
  (if (eq? (tpm2-environment-cleanup (current-tpm2-environment))
           'transient)
    (begin
     (apply tpm2-run-raw tcti args)
     (false-if-exception
      (apply tpm2-run-raw
        (append (list tcti)
                (list (string-append (dirname (car args))
                                     "/tpm2_flushcontext")
                      "-t")))))
    (apply tpm2-run-raw tcti args)))

(define (tpm2-run-capture tcti . args)
  "同上，但捕获 stdout（用于读 PCR、摘要等）。"
  (with-tcti tcti
             (lambda ()
               (apply invoke-capture (car args) (cdr args)))))

;;; ────────────────────────────────────────────────────────────
;;; 对象管理

(define* (tpm2-createprimary! tcti tpm2-tools-bin
                              #:key (out "primary.ctx"))
         "创建 SRK（owner hierarchy、RSA-2048、sha256 name）并保存 context。
返回 context 文件路径。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_createprimary")))
           (tpm2-run tcti bin "-C" "o" "-G" "rsa2048" "-g" "sha256" "-c" out))
         out)

;;; ────────────────────────────────────────────────────────────
;;; PCR policy（trial session）

(define* (tpm2-policy-pcr-digest! tcti tpm2-tools-bin pcr-value-file
                                  #:key (pcr "sha256:7")
                                  (out "policy.pcr.digest"))
         "TRIAL PolicyPCR：对指定 PCR 期望值（PCR-VALUE-FILE 为 tpm2_pcrread
的原始输出）生成 PolicyPCR digest。PCR7-only：默认 sha256:7。
返回 digest 文件路径。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_policypcr"))
               (sess (string-append out ".session.ctx")))
           (tpm2-run tcti (string-append tpm2-tools-bin "/tpm2_startauthsession")
                     "-S" sess)
           ;; 实测：-l "bank:index=值" 前向封印在 swtpm TCTI 下 0x1C4；
           ;; -f <原始 pcr 值> + -l <bank:index> 正常。
           (tpm2-run tcti bin "-S" sess "-L" out "-f" pcr-value-file "-l" pcr)
           (tpm2-run tcti (string-append tpm2-tools-bin "/tpm2_flushcontext") sess)
           (tpm2-flush-transients! tcti tpm2-tools-bin)
           out))

;;; ────────────────────────────────────────────────────────────
;;; sealed object

(define* (tpm2-create-sealed! tcti tpm2-tools-bin parent policy-digest-file
                              secret
                              #:key (public-out "seal.pub")
                              (private-out "seal.priv"))
         "创建带 POLICY-DIGEST-FILE 授权的 sealed object，密封 SECRET
（字节串，可含任意字节）。SECRET 经 stdin 传给 tpm2_create
（--key-file 语义），不落盘、不进 argv/environment。
PARENT 是持久句柄或 context。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_create"))
               ;; 实测：tpm2_create -L <文件> 在 swtpm TCTI 下 0x902；hex 正常
               (policy-hex (bytes->hex (call-with-input-file policy-digest-file
                                                             get-bytevector-all))))
           (with-tcti tcti
                      (lambda ()
                        (invoke-with-bytevector-stdin secret bin "-C" parent
                                                      "-u" public-out "-r" private-out
                                                      "-L" policy-hex "-i" "-" "-g" "sha256"))))
         (values public-out private-out))

(define* (tpm2-load-sealed! tcti tpm2-tools-bin parent public-file private-file
                            #:key (out "seal.ctx"))
         "把 sealed object 载入 TPM，返回 context 文件路径。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_load")))
           (tpm2-run tcti bin "-C" parent "-u" public-file "-r" private-file
                     "-c" out))
         out)

;;; ────────────────────────────────────────────────────────────
;;; unseal（真实 policy session）

(define* (tpm2-policy-pcr-session! tcti tpm2-tools-bin session-context
                                   #:key (pcr "sha256:7"))
         "真实 policy session 的 PolicyPCR：以 TPM 实际 PCR 值计算。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_policypcr")))
           (tpm2-run tcti bin "-S" session-context "-l" pcr)))

(define* (tpm2-unseal! tcti tpm2-tools-bin seal-context session-context
                       #:key (output #f))
         "unseal。OUTPUT 非 #f 时明文写入该文件（仅测试/调试用）；
为 #f 时返回子进程 stdout 的输入 port——明文只流经管道，不落盘、
不进 argv/env、不进入 Scheme 字符串，调用方负责把 port 内容写给
下游（如 cryptsetup stdin）并 close-port。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_unseal")))
           (if output
             (tpm2-run tcti bin "-c" seal-context
                       "-p" (string-append "session:" session-context)
                       "-o" output)
             (with-tcti tcti
                        (lambda ()
                          (open-pipe* OPEN_READ bin
                                      "-c" seal-context
                                      "-p" (string-append "session:" session-context)))))))

;;; ────────────────────────────────────────────────────────────
;;; PCR 读写与清理

(define* (tpm2-pcrread! tcti tpm2-tools-bin pcr
                        #:key (out #f))
         "读取 PCR（如 \"sha256:7\"）。OUT 为 #f 时返回原始字节的 hex 字符串。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_pcrread")))
           (if out
             (tpm2-run tcti bin pcr "-o" out)
             (let* ((tmp (string-append "/tmp/guixcfg-pcr-" (number->string (getpid))))
                    (hex (begin (tpm2-run tcti bin pcr "-o" tmp)
                                (call-with-input-file tmp
                                                      (lambda (p)
                                                        (bytes->hex (get-bytevector-all p)))))))
               (false-if-exception (delete-file tmp))
               hex))))

(define* (tpm2-pcrextend! tcti tpm2-tools-bin spec)
         "扩展 PCR，SPEC 如 \"7:sha256=<hex>\"。仅测试/调试用。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_pcrextend")))
           (tpm2-run tcti bin spec)))

(define* (tpm2-flush-transients! tcti tpm2-tools-bin)
         "显式 flush 全部 transient objects。仅限测试/调试手工调用；
不是生产语义：生产走 /dev/tpmrm0 内核 RM，禁止全局 flush。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_flushcontext")))
           (false-if-exception (tpm2-run tcti bin "-t"))))

(define* (tpm2-start-policy-session! tcti tpm2-tools-bin
                                     #:key (out "policy.session.ctx"))
         "启动真实 policy session 并保存 context。"
         (let ((bin (string-append tpm2-tools-bin "/tpm2_startauthsession")))
           (tpm2-run tcti bin "--policy-session" "-S" out))
         out)

(define (tpm2-flush-session! tcti tpm2-tools-bin session-context)
  "flush 指定 session（结束后清理）。"
  (let ((bin (string-append tpm2-tools-bin "/tpm2_flushcontext")))
    (false-if-exception (tpm2-run tcti bin session-context))))

;;; ────────────────────────────────────────────────────────────
;;; 辅助

(define (hex->bytes hex)
  "HEX 字符串 → bytevector。"
  (let* ((hex (string-downcase hex))
         (len (quotient (string-length hex) 2)))
    (let ((bv (make-bytevector len 0)))
      (let loop ((i 0))
        (when (< i len)
          (bytevector-u8-set! bv i
                              (string->number (substring hex (* i 2) (+ (* i 2) 2)) 16))
          (loop (1+ i))))
      bv)))

(define (bytes->hex bv)
  "bytevector → 小写 hex 字符串。"
  (string-join (map (lambda (b)
                      (string-append (number->string (quotient b 16) 16)
                                     (number->string (modulo b 16) 16)))
                    (bytevector->u8-list bv))
               ""))
