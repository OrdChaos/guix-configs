;;; vendor 证书记录契约：source 一律 file-append 进 virelith 频道的
;;; microsoft-secure-boot-certificates 包内文件（哈希固定于包内，
;;; 本仓库不重复维护）；db/KEK 分布固定。不构建、不联网：lowering
;;; 只计算 derivation（本地 store socket）。

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (guix derivations)          ; derivation?
             (guix monads)              ; mlet、run-with-store、mapm
             (guix store)               ; open-connection
             (guixcfg security certificates))

(test-runner-current (test-runner-simple))

(test-begin "vendor-certificates")

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
