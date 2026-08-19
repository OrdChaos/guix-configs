;;; 仓库根相对文件名的唯一 evaluation-time resolver。
;;;
;;; 项目约定（AGENT.md §Application layer / docs）：top-level
;;; 集中 secrets（secrets/...）与其它仓库根相对素材的引用必须经本
;;; helper——禁止调用方各自散布 "../../../secrets/..."，禁止硬编码
;;; checkout 绝对路径。
;;;
;;; 实现依据（pinned Guix 94a84f9 guix/gexp.scm）：local-file 是
;;; 宏，literal 相对路径按出现处 source directory 解析；非 literal
;;; 用 assume-source-relative-file-name 声明 source-relative。本模块
;;; 固定在 modules/guixcfg/utils/ 下：加载时经 %load-path 定位自身
;;; 源文件（search-path 对源码与已编译 .go 两种加载都稳定——
;;; current-filename 在编译缓存加载下为 #f，实测），上溯三层得到
;;; 仓库根，再拼 RELATIVE-PATH 得到绝对路径（local-file 对绝对输入
;;; 原样返回）——不依赖进程 CWD。
;;;
;;; local-file 把内容物化进 store（ciphertext 允许进 store），
;;; 不产生 runtime repository dependency：normal boot/runtime
;;; 不读取 Git checkout。

(define-module (guixcfg utils repository-source)
               #:use-module (guix gexp)   ; local-file、assume-source-relative-file-name
               #:export (repository-file repository-root))

;; 本模块所在目录（modules/guixcfg/utils/）。%load-path 必须含
;; modules/（guix repl -L modules / tests 的 add-to-load-path）。
(define %helper-dir
  (let ((f (search-path %load-path "guixcfg/utils/repository-source.scm")))
    (if f (dirname f)
        (error "repository-source: cannot locate module on %load-path (run with -L modules)"))))

;; 仓库根 = modules/guixcfg/utils/ 上溯三层。
(define (repository-root)
  "仓库根绝对路径（evaluation-time；不进入 runtime closure）。"
  (let loop ((depth 3) (dir %helper-dir))
    (if (zero? depth) dir (loop (- depth 1) (dirname dir)))))

(define (repository-file relative-path)
  "把仓库根相对路径 RELATIVE-PATH 解析为 local-file（file-like，
可进 gexp/store）。RELATIVE-PATH 必须是非空、非绝对、无 .. 逃逸的
相对路径。"
  (unless (and (string? relative-path)
               (> (string-length relative-path) 0)
               (not (string-prefix? "/" relative-path))
               (not (string-contains relative-path "..")))
          (error "repository-file: unsafe relative path" relative-path))
  (local-file (assume-source-relative-file-name
               (string-append (repository-root) "/" relative-path))))
