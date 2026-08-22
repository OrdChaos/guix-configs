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
;;; current-filename 在编译缓存加载下为 #f，实测），再**向上找含
;;; channels.lock.scm 的目录**作为仓库根（marker-based，与模块嵌套
;;; 深度/加载方式无关；VM 实测过固定深度上溯被环境差异打偏），拼
;;; RELATIVE-PATH 得到绝对路径（local-file 对绝对输入原样返回）——
;;; 不依赖进程 CWD。
;;;
;;; local-file 把内容物化进 store（ciphertext 允许进 store），
;;; 不产生 runtime repository dependency：normal boot/runtime
;;; 不读取 Git checkout。

(define-module (guixcfg utils repository-source)
               #:use-module (guix gexp)   ; local-file、assume-source-relative-file-name
               #:export (repository-file))

;; 本模块所在目录（modules/guixcfg/utils/）。%load-path 必须含
;; modules/（guix repl -L modules / tests 的 add-to-load-path）。
;; canonicalize-path 把结果锚定为绝对路径：search-path 对相对
;; %load-path 条目会返回相对路径（sudo/环境重置场景，VM 实测
;; root 解析错位到模块目录），锚定后 marker 上溯才稳定。
(define %helper-dir
  (let ((f (search-path %load-path "guixcfg/utils/repository-source.scm")))
    (if f
      (canonicalize-path (dirname f))
      (error "repository-source: cannot locate module on %load-path (run with -L modules)"))))

(define (repository-root)
  "仓库根绝对路径：从本模块目录向上找含 channels.lock.scm 的目录
（marker-based；evaluation-time，不进入 runtime closure）。"
  (let loop ((dir %helper-dir))
    (cond ((file-exists? (string-append dir "/channels.lock.scm")) dir)
      ((string=? dir "/")
       (error "repository-source: repo root not found (no channels.lock.scm above)"
              %helper-dir))
      (else (loop (dirname dir))))))

(define (repository-file relative-path)
  "把仓库根相对路径 RELATIVE-PATH 解析为 local-file（file-like，
可进 gexp/store）。RELATIVE-PATH 必须是非空、非绝对、无 .. 逃逸的
相对路径；容忍 \"./\" 前缀（归一化）。解析结果不存在时抛错并打印
完整现场（root/rel/helper-dir）——不让 local-file 的
canonicalize-path 报裸路径。"
  (let ((rel (if (string-prefix? "./" relative-path)
               (substring relative-path 2)
               relative-path)))
    (unless (and (string? rel)
                 (> (string-length rel) 0)
                 (not (string-prefix? "/" rel))
                 (not (string-contains rel "..")))
      (error "repository-file: unsafe relative path" relative-path))
    (let ((path (string-append (repository-root) "/" rel)))
      (unless (file-exists? path)
        (error "repository-file: resolved file does not exist"
               path (repository-root) relative-path %helper-dir))
      (local-file (assume-source-relative-file-name path)))))
