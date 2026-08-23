;;; 构建期在线数据机制测试：(guixcfg utils online-file)。
;;;
;;; 覆盖：
;;;   - record 构造不取网（构造/求值绝不触发下载——AGENT.md §4）；
;;;   - sha256 参数校验（#f 或 nix-base32 字符串）；
;;;   - fetch-url-cached 的 cache-first 语义（命中不重复下载、
;;;     URL 变化重新下载、.url/.sha256 sidecar 正确）；
;;;   - lowering：#f 模式经 binary-file 进 store（内容一致）；
;;;     sha256 模式产生 fixed-output derivation（只声明不构建，
;;;     不访问网络）。
;;; 全部用假 fetcher + 临时 cache 目录，不访问公网。

(use-modules (guix store)           ; %store
             (guix monads)
             (guix derivations)     ; derivation?、fixed-output-derivation?
             (guix gexp)            ; lower-object
             (guix base32)          ; bytevector->nix-base32-string
             (gcrypt hash)          ; sha256
             (guix build utils)     ; mkdir-p、delete-file-recursively
             (rnrs bytevectors)
             (rnrs io ports)        ; get-bytevector-all
             (srfi srfi-13)         ; string-trim-right
             (guixcfg utils online-file)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "online-file")

(define %store (open-connection))

(define %tmp-root
  (string-append (or (getenv "TMPDIR") "/tmp") "/guixcfg-online-file-test"))

(define (cleanup!)
  (false-if-exception (delete-file-recursively %tmp-root)))

(define %fake-bytes (string->utf8 "fake model bytes"))
(define %fetch-url "https://example.invalid/model.bin")

;; 计数假 fetcher：记录调用次数，返回固定字节。
(define (make-fake-fetcher)
  (let ((calls 0))
    (lambda* (url #:key (peek #f))
      (if peek
          calls
          (begin (set! calls (+ calls 1)) %fake-bytes)))))

;; ── 1. 构造不取网 ─────────────────────────────────────────
(cleanup!)
(let* ((fetcher (make-fake-fetcher))
       (f (parameterize ((%online-fetcher fetcher)
                         (%online-cache-directory
                          (string-append %tmp-root "/construct")))
            (online-file "model.bin" %fetch-url #:sha256 #f))))
  (test-assert "construct: returns <online-file>" (online-file? f))
  (test-equal "construct: name kept" "model.bin" (online-file-name f))
  (test-equal "construct: url kept" %fetch-url (online-file-url f))
  (test-assert "construct: sha256 defaults to #f"
               (not (online-file-sha256 f)))
  (test-equal "construct: fetcher not called" 0 (fetcher #f #:peek #t))
  (test-assert "construct: no cache dir created"
               (not (file-exists? (string-append %tmp-root "/construct")))))

(test-assert "construct: sha256 string accepted"
             (online-file?
              (online-file "m.bin" %fetch-url
                           #:sha256
                           "1k7f1npaj2hhfn5wzkdqxf92hr5pkrkh6ac0dk3i8wxg8g7sgz65")))

(test-error "construct: non-string sha256 rejected"
            'misc-error
            (online-file "m.bin" %fetch-url #:sha256 123))

;; ── 2. fetch-url-cached：cache-first 语义 ─────────────────
(cleanup!)
(let ((fetcher (make-fake-fetcher))
      (dir (string-append %tmp-root "/cache")))
  (parameterize ((%online-fetcher fetcher)
                 (%online-cache-directory dir))
    (test-equal "fetch: first call downloads"
                %fake-bytes
                (fetch-url-cached "model.bin" %fetch-url))
    (test-equal "fetch: fetcher called once" 1 (fetcher #f #:peek #t))
    (test-assert "fetch: cache file written"
                 (file-exists? (string-append dir "/model.bin")))
    (test-assert "fetch: .url sidecar written"
                 (file-exists? (string-append dir "/model.bin.url")))
    (test-equal "fetch: .sha256 sidecar matches content"
                (bytevector->nix-base32-string (sha256 %fake-bytes))
                (call-with-input-file (string-append dir "/model.bin.sha256")
                  (lambda (p) (string-trim-right (get-string-all p)))))
    (test-equal "fetch: cache hit serves same bytes"
                %fake-bytes
                (fetch-url-cached "model.bin" %fetch-url))
    (test-equal "fetch: cache hit does not re-download"
                1 (fetcher #f #:peek #t))
    ;; URL 变化 = 新资源 → 重新下载
    (fetch-url-cached "model.bin" "https://example.invalid/model-v2.bin")
    (test-equal "fetch: url change re-downloads" 2 (fetcher #f #:peek #t))))

;; ── 3. lowering：#f 模式进 store（binary-file）─────────────
(cleanup!)
(let ((fetcher (make-fake-fetcher)))
  (parameterize ((%online-fetcher fetcher)
                 (%online-cache-directory (string-append %tmp-root "/lower")))
    (let ((path (run-with-store
                 %store
                 (lower-object (online-file "model.bin" %fetch-url
                                            #:sha256 #f)))))
      (test-assert "lower #f: store path produced" (string? path))
      (test-equal "lower #f: content matches"
                  %fake-bytes
                  (call-with-input-file path get-bytevector-all))
      (test-equal "lower #f: fetched exactly once" 1 (fetcher #f #:peek #t)))))

;; ── 4. lowering：sha256 模式 = fixed-output derivation ────
(let ((drv (run-with-store
            %store
            (lower-object
             (online-file "model.bin" %fetch-url
                          #:sha256
                          "1k7f1npaj2hhfn5wzkdqxf92hr5pkrkh6ac0dk3i8wxg8g7sgz65")))))
  (test-assert "lower sha256: returns derivation" (derivation? drv))
  (test-assert "lower sha256: fixed-output derivation"
               (fixed-output-derivation? drv)))

(cleanup!)
(test-end "online-file")
