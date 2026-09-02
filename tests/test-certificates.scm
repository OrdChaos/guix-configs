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
  (test-equal "db 证书 5 张"
    5
    (length (vendor-certificates-for 'db)))
  (test-equal "KEK 证书 2 张"
    2
    (length (vendor-certificates-for 'KEK)))
  (test-equal "共 7 张"
    7
    (length %vendor-certificates))
  (test-assert "全部 source 是证书包内 file-append"
    (every (lambda (cert)
             (let ((src (vendor-certificate-source cert)))
               (and (file-append? src)
                    (eq? (file-append-base src)
                         microsoft-secure-boot-certificates)
                    (string-prefix?
                     "/share/secure-boot/microsoft/"
                     (string-join (file-append-suffix src) "")))))
           %vendor-certificates))
  (test-assert "安装路径与包 catalog 的 install-name 一致"
    (every (lambda (cert)
             (let ((path (string-join (file-append-suffix
                                       (vendor-certificate-source cert))
                                      "")))
               (member (string-drop path (string-length
                                          "/share/secure-boot/microsoft/"))
                       (map car %microsoft-secure-boot-certs))))
           %vendor-certificates)))

(test-group "lowering"
  (test-assert "全部 source 降级为同一个证书包 derivation（不构建、不联网）"
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
(define %fail-count (test-runner-fail-count (test-runner-get)))
(test-end "vendor-certificates")

(exit (if (zero? %fail-count) 0 1))
