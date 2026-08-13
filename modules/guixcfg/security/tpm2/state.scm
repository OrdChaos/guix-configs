;;; TPM enrollment 管理状态（PCR7-only 简化版）。
;;;
;;;   /persist/system/tpm2/state.scm          enrollment 状态（atomic 写）
;;;   /persist/system/tpm2/objects/           sealed blobs（seal.pub/priv）
;;;
;;; 只有一种状态：enrolled（或未 enrolled）。没有 pending/active 提升、
;;; 没有 approved-pcr7 二阶段批准——enrollment 的授权依据就是 TPM
;;; sealed object 内的 PolicyPCR(sha256:7) 本身，state.scm 只是管理
;;; 元数据（哪些 keyslot、何时、PCR7 当时值用于诊断）。
;;;
;;; 可持久化：sealed public/private blob、enrollment 元数据、LUKS
;;; keyslot 引用。
;;; 不可持久化：plaintext credential、临时 session context。
;;;
;;; 注意：sealed blob 需要「解锁前可读」，不能只放 /persist/system
;;; （访问它要先解锁 LUKS，循环依赖）——/persist 侧的 blobs 是管理
;;; 副本/备份，解锁前读取用 ESP 侧副本（见 (guixcfg boot tpm-unlock)
;;; 与 docs/boot.md 第 16.4 节）。

(define-module (guixcfg security tpm2 state)
               #:use-module (guixcfg utils atomic-file)  ; atomic-write-file!
               #:use-module (guix build utils)           ; mkdir-p
               #:use-module (guix records)               ; define-record-type*
               #:use-module (ice-9 rdelim)               ; read
               #:use-module (srfi srfi-1)                ; assq-ref
               #:export (%tpm2-state-dir
                         %tpm2-state-format-version
                         %tpm2-pcr-bank
                         %tpm2-pcr-list
                         <tpm2-enrollment>
                         tpm2-enrollment make-tpm2-enrollment tpm2-enrollment?
                         tpm2-enrollment-id
                         tpm2-enrollment-keyslot
                         tpm2-enrollment-pcr-bank
                         tpm2-enrollment-pcr-list
                         tpm2-enrollment-pcr7
                         tpm2-enrollment-created
                         tpm2-enrollment-notes
                         read-tpm2-state
                         write-tpm2-state!
                         tpm2-enrolled?
                         enrollment-artifact-dir
                         enrollment-artifacts-present?))

;; 固定路径。PCR7-only：单一 enrollment，无 pending/active 分目录。
(define %tpm2-state-dir "/persist/system/tpm2")
(define %tpm2-state-file (string-append %tpm2-state-dir "/state.scm"))

;; 本项目 PCR 选择的固定事实（docs/boot.md 第 16.4 节）：PCR7-only，
;; SHA-256 bank。enrollment 与 initrd 解锁共用，不允许配置漂移。
(define %tpm2-pcr-bank "sha256")
(define %tpm2-pcr-list '("7"))

(define %tpm2-state-format-version 1)

(define-record-type* <tpm2-enrollment>
                     tpm2-enrollment make-tpm2-enrollment
                     tpm2-enrollment?
                     (id      tpm2-enrollment-id)      ; 字符串，enroll-<time>
                     (keyslot tpm2-enrollment-keyslot) ; LUKS keyslot 编号（整数）
                     (pcr-bank tpm2-enrollment-pcr-bank
                               (default %tpm2-pcr-bank))
                     (pcr-list tpm2-enrollment-pcr-list
                               (default %tpm2-pcr-list))
                     (pcr7    tpm2-enrollment-pcr7
                              (default #f))            ; enrollment 时 PCR7（诊断用，
                     ; 不是授权依据）
                     (created tpm2-enrollment-created) ; unix time
                     (notes   tpm2-enrollment-notes
                              (default '())))

;;; ────────────────────────────────────────────────────────────
;;; 序列化（alist 形式持久化，原子写；复用 atomic-file 的 .prev 回退）。

(define (enrollment->alist e)
  `((id . ,(tpm2-enrollment-id e))
    (keyslot . ,(tpm2-enrollment-keyslot e))
    (pcr-bank . ,(tpm2-enrollment-pcr-bank e))
    (pcr-list . ,(tpm2-enrollment-pcr-list e))
    ,@(if (tpm2-enrollment-pcr7 e)
        `((pcr7 . ,(tpm2-enrollment-pcr7 e)))
        '())
    (created . ,(tpm2-enrollment-created e))
    ,@(if (null? (tpm2-enrollment-notes e))
        '()
        `((notes . ,(tpm2-enrollment-notes e))))))

(define (alist->enrollment alist)
  (let ((id (assq-ref alist 'id))
        (keyslot (assq-ref alist 'keyslot))
        (pcr-bank (assq-ref alist 'pcr-bank))
        (pcr-list (assq-ref alist 'pcr-list))
        (pcr7 (assq-ref alist 'pcr7))
        (created (assq-ref alist 'created))
        (notes (assq-ref alist 'notes)))
    (unless (and (string? id)
                 (integer? keyslot)
                 (string? pcr-bank)
                 (and (list? pcr-list) (every string? pcr-list))
                 (or (not pcr7) (string? pcr7))
                 (integer? created))
      (error "tpm2 state 格式错误" alist))
    (tpm2-enrollment (id id) (keyslot keyslot)
                     (pcr-bank pcr-bank) (pcr-list pcr-list)
                     (pcr7 pcr7) (created created)
                     (notes (or notes '())))))

(define* (read-tpm2-state #:optional (path %tpm2-state-file))
         "读取 state.scm；不存在返回 #f（未 enrolled）。
主文件损坏时回退 .prev；.prev 也不存在/也损坏则重新抛出错误
（状态文件损坏是管理问题，不应静默当作未 enrolled）。
返回 <tpm2-enrollment> 或 #f。"
         (define (try p)
           (let ((data (call-with-input-file p read)))
             (and (list? data)
                  (assq-ref data 'enrollment)
                  (alist->enrollment (assq-ref data 'enrollment)))))
         (if (file-exists? path)
           (catch #t
             (lambda () (try path))
             (lambda (key . args)
               (let ((prev (string-append path ".prev")))
                 (if (file-exists? prev)
                   (try prev)
                   (apply throw key args)))))
           (let ((prev (string-append path ".prev")))
             (and (file-exists? prev) (try prev)))))

(define* (write-tpm2-state! enrollment
                            #:optional (path %tpm2-state-file))
         "原子写 state.scm（crash-durable：先保留旧【可解析】状态为 .prev，
再写主文件）。ENROLLMENT 为 <tpm2-enrollment> 或 #f（未 enrolled）。"
         (mkdir-p (dirname path))
         (let ((previous (and (or (file-exists? path)
                                  (file-exists? (string-append path ".prev")))
                              (false-if-exception (read-tpm2-state path)))))
           (when previous
             (atomic-write-file! (string-append path ".prev")
                                 (lambda (port)
                                   (write `((format-version . ,%tpm2-state-format-version)
                                            (enrollment . ,(enrollment->alist previous)))
                                          port)
                                   (newline port))))
           (atomic-write-file! path
                               (lambda (port)
                                 (write `((format-version . ,%tpm2-state-format-version)
                                          (enrollment . ,(and enrollment
                                                              (enrollment->alist enrollment))))
                                        port)
                                 (newline port)))))

(define (tpm2-enrolled? enrollment)
  "ENROLLMENT 非 #f 即视为已 enrolled（PCR7-only 无中间状态）。"
  (not (not enrollment)))

;;; ────────────────────────────────────────────────────────────
;;; artifact 目录（/persist 侧管理副本；解锁前读取用 ESP 副本）

(define* (enrollment-artifact-dir #:optional (base %tpm2-state-dir))
         "ENROLLMENT 的 sealed blob 目录（/persist 侧副本）：
OBJECTS/seal.pub、OBJECTS/seal.priv。单 enrollment，无子目录。"
         (string-append (string-trim-right base #\/) "/objects"))

(define (enrollment-artifacts-present? enrollment base)
  "ENROLLMENT 对应的 sealed blobs 是否完整存在（两个都在才算）。
base 是 artifact 目录根。"
  (let* ((dir (enrollment-artifact-dir base))
         (pub (string-append dir "/seal.pub"))
         (priv (string-append dir "/seal.priv")))
    (and (tpm2-enrolled? enrollment)
         (file-exists? pub)
         (file-exists? priv))))
