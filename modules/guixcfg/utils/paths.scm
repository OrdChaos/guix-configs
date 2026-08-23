;;; 路径谓词原语（跨领域共享）。
;;;
;;; persistence 各执行器（application / machine-state）对 backing 等相对
;;; 路径的合法性判定是同一份契约——单一实现，禁止各自复制（invariants
;;; §13 second-implementation trigger）。

(define-module (guixcfg utils paths)
               #:use-module (srfi srfi-13)  ; string-prefix?/string-contains/string-suffix?
               #:export (valid-relative-path?))

(define (valid-relative-path? p)
  "P 是否是合法的相对路径（非空、非绝对、无 .. 逃逸）。"
  (and (string? p)
       (> (string-length p) 0)
       (not (string-prefix? "/" p))
       (not (string=? p ".."))
       (not (string-prefix? "../" p))
       (not (string-contains p "/../"))
       (not (string-suffix? "/.." p))))
