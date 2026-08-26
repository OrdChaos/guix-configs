;;; 构建期在线数据机制测试：(guixcfg utils online-file)。
;;;
;;; 覆盖：
;;;   - record 构造不取网（构造/求值绝不触发下载——AGENT.md §4）；
;;;   - sha256 参数校验（#f 或 nix-base32 字符串）；
;;;   - refresh 参数校验（默认 #f；与 sha256 互斥）；
;;;   - fetch-url-cached 的 cache-first 语义（命中不重复下载、
;;;     URL 变化重新下载、.url/.sha256 sidecar 正确）；
;;;   - fetch-url-refresh 语义（每次调用都重新下载；失败时回退
;;;     有效缓存、无有效缓存则透传错误、URL 不匹配不复用）；
;;;   - lowering：#f 模式经 binary-file 进 store（内容一致）；
;;;     refresh 模式每次 lowering 重新下载、失败回退缓存构建；
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

;; ── 5. 构造：refresh 参数 ─────────────────────────────────
(cleanup!)
(let* ((fetcher (make-fake-fetcher))
       (f (parameterize ((%online-fetcher fetcher)
                         (%online-cache-directory
                          (string-append %tmp-root "/construct-refresh")))
                        (online-file "model.bin" %fetch-url #:refresh #t))))
  (test-assert "construct refresh: returns <online-file>" (online-file? f))
  (test-assert "construct refresh: refresh kept" (online-file-refresh f))
  (test-assert "construct refresh: default is #f"
               (not (online-file-refresh
                     (online-file "model.bin" %fetch-url))))
  (test-equal "construct refresh: fetcher not called" 0 (fetcher #f #:peek #t))
  (test-error "construct refresh: pinned sha256 + refresh rejected"
              'misc-error
              (online-file "m.bin" %fetch-url
                           #:sha256
                           "1k7f1npaj2hhfn5wzkdqxf92hr5pkrkh6ac0dk3i8wxg8g7sgz65"
                           #:refresh #t)))

;; ── 6. fetch-url-refresh：每次下载 + 失败回退 ───────────────
(cleanup!)
(let ((fetcher (make-fake-fetcher))
      (dir (string-append %tmp-root "/refresh")))
  (parameterize ((%online-fetcher fetcher)
                 (%online-cache-directory dir))
                (test-equal "refresh: first call downloads"
                            %fake-bytes
                            (fetch-url-refresh "model.bin" %fetch-url))
                (test-equal "refresh: fetcher called once" 1 (fetcher #f #:peek #t))
                (test-equal "refresh: second call downloads again"
                            %fake-bytes
                            (fetch-url-refresh "model.bin" %fetch-url))
                (test-equal "refresh: fetcher called on every call" 2
                            (fetcher #f #:peek #t))
                (test-assert "refresh: cache file written"
                             (file-exists? (string-append dir "/model.bin")))
                (test-assert "refresh: .url sidecar written"
                             (file-exists? (string-append dir "/model.bin.url")))
                (test-equal "refresh: .sha256 sidecar matches content"
                            (bytevector->nix-base32-string (sha256 %fake-bytes))
                            (call-with-input-file (string-append dir "/model.bin.sha256")
                                                  (lambda (p) (string-trim-right (get-string-all p)))))
                
                ;; 失败回退：有效缓存 → 返回缓存字节 + stderr 警告
                (let ((err-out (open-output-string)))
                  (parameterize ((%online-fetcher (lambda (url) (error "network down")))
                                 (current-error-port err-out))
                                (test-equal "refresh: failure falls back to valid cache"
                                            %fake-bytes
                                            (fetch-url-refresh "model.bin" %fetch-url)))
                  (test-assert "refresh: fallback warns on stderr"
                               (string-contains (get-output-string err-out)
                                                "using cached copy")))
                ;; 失败且无缓存：透传错误
                (test-error "refresh: failure without cache propagates"
                            'misc-error
                            (parameterize ((%online-fetcher
                                            (lambda (url) (error "network down"))))
                                          (fetch-url-refresh "no-cache.bin" %fetch-url)))
                ;; 失败且缓存 URL 不匹配：透传错误（不同 URL 的缓存不复用）
                (let ((fetcher2 (make-fake-fetcher)))
                  (parameterize ((%online-fetcher fetcher2))
                                (fetch-url-refresh "mismatch.bin" "https://example.invalid/url-a")))
                (test-error "refresh: failure with url-mismatched cache propagates"
                            'misc-error
                            (parameterize ((%online-fetcher
                                            (lambda (url) (error "network down"))))
                                          (fetch-url-refresh "mismatch.bin"
                                                             "https://example.invalid/url-b")))))

;; ── 7. lowering：refresh 模式 ─────────────────────────────
(cleanup!)
(let ((fetcher (make-fake-fetcher)))
  (parameterize ((%online-fetcher fetcher)
                 (%online-cache-directory
                  (string-append %tmp-root "/lower-refresh")))
                (let ((p1 (run-with-store %store
                                          (lower-object (online-file "model.bin" %fetch-url
                                                                     #:refresh #t))))
                      (p2 (run-with-store %store
                                          (lower-object (online-file "model.bin" %fetch-url
                                                                     #:refresh #t)))))
                  (test-assert "lower refresh: store path produced" (string? p1))
                  (test-equal "lower refresh: content matches"
                              %fake-bytes
                              (call-with-input-file p1 get-bytevector-all))
                  (test-equal "lower refresh: fetcher called once per lowering" 2
                              (fetcher #f #:peek #t))
                  (test-equal "lower refresh: content-addressed path stable" p1 p2))))

;; refresh 失败时回退缓存，lowering 仍成功
(cleanup!)
(let ((fetcher (make-fake-fetcher)))
  (parameterize ((%online-fetcher fetcher)
                 (%online-cache-directory
                  (string-append %tmp-root "/lower-fallback")))
                (fetch-url-cached "model.bin" %fetch-url)   ; 预热缓存
                (parameterize ((%online-fetcher (lambda (url) (error "network down"))))
                              (let ((p (run-with-store %store
                                                       (lower-object (online-file "model.bin" %fetch-url
                                                                                  #:refresh #t)))))
                                (test-assert "lower refresh fallback: store path produced"
                                             (string? p))
                                (test-equal "lower refresh fallback: cached content used"
                                            %fake-bytes
                                            (call-with-input-file p get-bytevector-all))))))

(cleanup!)
(test-end "online-file")
