;;; source-module-closure 的项目 select?：guix/gnu 之外放行 (guixcfg …)。
;;;
;;; source-module-closure 的默认 select? 只收 (guix …)/(gnu …) 模块，
;;; (guixcfg …) 会被静默过滤导致运行期 no code for module——所有生成
;;; runtime 程序（program-file/activation/initrd）的模块闭包都用本
;;; 谓词，禁止各处复制（invariants §13 second-implementation trigger）。

(define-module (guixcfg utils module-closure)
               #:use-module (guix modules)  ; guix-module-name?、source-module-closure
               #:export (guixcfg-module-select?))

(define (guixcfg-module-select? name)
  "source-module-closure 的 #:select?：guix/gnu 模块 + 项目 (guixcfg …)。"
  (or (guix-module-name? name)
      (eq? (car name) 'guixcfg)))
