;;; vendor 证书记录契约：source 一律 file-append 进 virelith 频道的
;;; microsoft-secure-boot-certificates 包内文件（哈希固定于包内，
;;; 本仓库不重复维护）；db/KEK 分布固定。不构建、不联网：lowering
;;; 只计算 derivation（本地 store socket）。

(use-modules (srfi srfi-1)
             (srfi srfi-13)             ; string-join、string-drop
             (srfi srfi-64)
             (guix derivations)          ; derivation?
             (guix gexp)                ; file-append、file-append?
             (guix monads)              ; mlet、run-with-store、mapm
             (guix store)               ; open-connection
             (guixcfg security certificates)
             (virelith packages secure-boot)) ; microsoft-secure-boot-certificates、%microsoft-secure-boot-certs

(test-runner-current (test-runner-simple))

(test-begin "vendor-certificates")

(test-group "record contract"
  (test-equal "db carries 5 certificates"
    5
    (length (vendor-certificates-for 'db)))
  (test-equal "KEK carries 2 certificates"
    2
    (length (vendor-certificates-for 'KEK)))
  (test-equal "7 certificates in total"
    7
    (length %vendor-certificates))
  (test-assert "all sources are file-append inside the certificate package"
    (every (lambda (cert)
             (let ((src (vendor-certificate-source cert)))
               (and (file-append? src)
                    (eq? (file-append-base src)
                         microsoft-secure-boot-certificates)
                    (string-prefix?
                     "/share/secure-boot/microsoft/"
                     (string-join (file-append-suffix src) "")))))
           %vendor-certificates))
  (test-assert "install paths match the package catalog install-names"
    (every (lambda (cert)
             (let ((path (string-join (file-append-suffix
                                       (vendor-certificate-source cert))
                                      "")))
               (member (string-drop path (string-length
                                          "/share/secure-boot/microsoft/"))
                       (map car %microsoft-secure-boot-certs))))
           %vendor-certificates)))

(test-group "lowering"
  (test-assert "all sources lower to one certificate package derivation (no build, no network)"
    (run-with-store (open-connection)
      (mlet %store-monad ((drvs (mapm %store-monad
                                      (lambda (cert)
                                        (lower-object
                                         (vendor-certificate-source cert)))
                                      %vendor-certificates)))
        (return (and (= 7 (length drvs))
                     (every derivation? drvs)
                     (= 1 (length (delete-duplicates drvs)))))))))

;; Evaluation of this module performs no network I/O; the only external
;; interaction is the local store socket used above.
(test-end "vendor-certificates")

;; 注意：套件内测试文件绝不调用 exit——tests/run-tests.scm 在每个文件
;; 加载后从 runner 摘取计数并累计判定（test-certificates 曾在文件尾
;; exit，导致其后的 test-deploy/test-install-orchestration/…全部被
;; 静默截断，退出码还显示 0）。
