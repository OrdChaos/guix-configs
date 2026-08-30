;;; 模块编译冒烟测试：全部模块显式 compile-file，加载错误和“未绑定变量”
;;; 警告都会在测试阶段暴露，不用等到 VM 里跑 apply 才发现。
;;;
;;; 注意：primitive-load / resolve-module 走的是快速求值路径，不产生
;;; 未绑定变量警告；compile-file 做完整分析，必须用它。由于显式编译，
;;; 本测试也不受 auto-compile 的 .go 缓存影响。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）；单独运行也要
;;; 可用，这里自备 load path（模块顶层求值依赖 %load-path，如
;;; repository-source 的 search-path 定位）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (system base compile)  ; compile-file
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

;; 依赖顺序排列：被依赖的模块先编译注册。清单不再手工维护——
;; 自动扫描 modules/guixcfg 全部 .scm，按 #:use-module 行对 guixcfg
;; 内部依赖做拓扑排序（冷 ccache 下 compile-file 对依赖缺失报
;; "no code for module"；漏清单会让模块以旧 record 类型残留，导致
;; accessor wrong-type-arg——fastfetch 2026-08 实测）。新增应用/模块
;; 无需改本文件。

(use-modules (ice-9 ftw)     ; scandir
             (ice-9 regex)   ; regexp-exec、make-regexp
             (ice-9 rdelim)) ; read-line

(define (scheme-files-under dir)
  "DIR 下全部 .scm 文件（递归）。"
  (let loop ((dir dir))
    (append-map (lambda (e)
                  (let ((p (string-append dir "/" e)))
                    (cond ((string-suffix? ".scm" e) (list p))
                      ((and (not (string-prefix? "." e))
                            (eq? 'directory (stat:type (stat p))))
                       (loop p))
                      (else '()))))
                (or (false-if-exception (scandir dir)) '()))))

(define (module-name-of file)
  "从 FILE 的 define-module 行提取模块名（符号列表）。"
  (let ((rx (make-regexp "\\(define-module \\(([a-z0-9-]+( [a-z0-9-]+)*)")))
    (let ((m (regexp-exec rx
                          (call-with-input-file file
                                                (lambda (p) (read-string p))))))
      (if m
        (map string->symbol (string-split (match:substring m 1) #\space))
        (error "no define-module in" file)))))

(define (guixcfg-use-modules file)
  "FILE 中 #:use-module 引用的 guixcfg 模块名列表（跳过注释行）。"
  (let ((rx (make-regexp "#:use-module[ \t]+\\(\\(?guixcfg(( [a-z0-9-]+)*)")))
    (let loop ((lines (call-with-input-file file
                                            (lambda (p)
                                              (let loop ((acc '()))
                                                (let ((l (read-line p)))
                                                  (if (eof-object? l) (reverse acc)
                                                    (loop (cons l acc))))))))
               (acc '()))
      (if (null? lines)
        (reverse acc)
        (let ((line (car lines)))
          (if (or (string-prefix? ";;" line)
                  (not (string-contains line "#:use-module")))
            (loop (cdr lines) acc)
            (let ((m (regexp-exec rx line)))
              (loop (cdr lines)
                    (if m
                      (cons (cons 'guixcfg
                                  (map string->symbol
                                       (filter (lambda (s) (> (string-length s) 0))
                                               (string-split (match:substring m 1)
                                                             #\space))))
                            acc)
                      acc)))))))))

(define (topo-sort nodes edges)
  "NODES 按 EDGES（alist: node -> 依赖列表）拓扑排序；有环报错。"
  (let loop ((remaining (map (lambda (n)
                               (cons n (or (assoc-ref edges n) '())))
                             nodes))
             (ready (filter (lambda (n)
                              (null? (or (assoc-ref edges n) '())))
                            nodes))
             (acc '()))
    (if (null? ready)
      (if (= (length acc) (length nodes))
        (reverse acc)
        (error "module dependency cycle" nodes edges))
      (let ((n (car ready)))
        (let* ((remaining* (map (lambda (e)
                                  (cons (car e)
                                        (filter (lambda (d) (not (equal? d n)))
                                                (cdr e))))
                                remaining))
               (dependents (map car (filter (lambda (e)
                                              (member n (cdr e)))
                                            edges)))
               (ready* (append (cdr ready)
                               (filter (lambda (m)
                                         (and (not (member m acc))
                                              (not (member m ready))
                                              (null? (or (assoc-ref remaining* m)
                                                         '()))))
                                       dependents))))
          (loop remaining* ready* (cons n acc)))))))

(define %all-modules
  (let* ((files (scheme-files-under "modules/guixcfg"))
         (nodes (map module-name-of files))
         (edges (map (lambda (f)
                       (cons (module-name-of f) (guixcfg-use-modules f)))
                     files)))
    (topo-sort nodes edges)))

(define (module-file name)
  (string-append "modules/"
                 (string-join (map symbol->string name) "/")
                 ".scm"))

(test-begin "modules-compile")

(test-assert "all modules compile and load without unbound-variable warnings"
             (let ((warnings (open-output-string)))
               (let ((ok
                      (every (lambda (name)
                               (catch #t
                                 (lambda ()
                                   (parameterize ((current-warning-port warnings))
                                                 (compile-file (module-file name) #:to 'value))
                                   #t)
                                 (lambda (key . args)
                                   (format (current-error-port) "module compile failed: ~a (~a ~a)~%"
                                           name key args)
                                   #f)))
                             %all-modules)))
                 (let ((text (get-output-string warnings)))
                   (when (string-contains text "unbound")
                     (format (current-error-port) "~a" text))
                   (and ok (not (string-contains text "unbound")))))))

;; operating-system 的 services 等字段是延迟求值的，compile-file 不会
;; 触发字段校验；这里显式实例化 %vm-os，让“services 字段必须是服务列表”
;; 这类错误在测试期暴露，而不是留到 system build。
(test-assert "hosts/vm.scm %vm-os instantiates (valid services field)"
             (let ((os (module-ref (resolve-module '(guixcfg hosts vm)) '%vm-os)))
               (list? ((@ (gnu system) operating-system-services) os))))

;; tools/*.scm 是 CLI 脚本（无 define-module）：脚本里的未绑定变量只有
;; 运行到对应分支才炸（实测教训：(unresolved) 曾在 disk-install 的
;; inspect 分支存活）。compile-file 到临时 .go（不执行脚本），编译警告
;; 经 current-warning-port 捕获。
(test-assert "tools/*.scm compile without unbound-variable warnings"
             (let ((warnings (open-output-string)))
               (let ((ok (every (lambda (file)
                                  (catch #t
                                    (lambda ()
                                      (parameterize ((current-warning-port warnings))
                                                    (compile-file
                                                     (string-append "tools/" file)
                                                     #:output-file
                                                     "/tmp/guixcfg-tools-compile-check.go"))
                                      #t)
                                    (lambda (key . args)
                                      (format (current-error-port)
                                              "tool compile failed: ~a (~a ~a)~%"
                                              file key args)
                                      #f)))
                                (or (scandir "tools"
                                             (lambda (f)
                                               (string-suffix? ".scm" f)))
                                    '()))))
                 (false-if-exception
                  (delete-file "/tmp/guixcfg-tools-compile-check.go"))
                 (let ((text (get-output-string warnings)))
                   (when (string-contains text "unbound")
                     (format (current-error-port) "~a" text))
                   (and ok (not (string-contains text "unbound")))))))

(test-end)
