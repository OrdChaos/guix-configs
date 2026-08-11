;;; 模块编译冒烟测试：全部模块显式 compile-file，加载错误和“未绑定变量”
;;; 警告都会在测试阶段暴露，不用等到 VM 里跑 apply 才发现。
;;;
;;; 注意：primitive-load / resolve-module 走的是快速求值路径，不产生
;;; 未绑定变量警告；compile-file 做完整分析，必须用它。由于显式编译，
;;; 本测试也不受 auto-compile 的 .go 缓存影响。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。

(use-modules (system base compile)  ; compile-file
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

;; 依赖顺序排列：被依赖的模块先编译注册。
(define %all-modules
  '((guixcfg utils atomic-file)
    (guixcfg storage model)
    (guixcfg storage policies)
    (guixcfg storage plan)
    (guixcfg storage validate)
    (guixcfg storage device)
    (guixcfg storage partition)
    (guixcfg storage filesystem)
    (guixcfg storage subvolume)
    (guixcfg storage root-generation)
    (guixcfg storage install)
    (guixcfg storage commit)
    (guixcfg boot initrd)
    (guixcfg boot boot-state)
    (guixcfg security certificates)
    (guixcfg boot uki)
    (guixcfg boot uki-bootloader)
    (guixcfg services ephemeral-root)
    (guixcfg system common)
    (guixcfg system packages)
    (guixcfg system file-systems)
    (guixcfg hosts vm)
    (guixcfg hosts laptop)))

(define (module-file name)
  (string-append "modules/"
                 (string-join (map symbol->string name) "/")
                 ".scm"))

(test-begin "modules-compile")

(test-assert "全部模块可编译加载，且无未绑定变量警告"
             (let ((warnings (open-output-string)))
               (let ((ok
                      (every (lambda (name)
                               (catch #t
                                 (lambda ()
                                   (parameterize ((current-warning-port warnings))
                                                 (compile-file (module-file name) #:to 'value))
                                   #t)
                                 (lambda (key . args)
                                   (format (current-error-port) "模块编译失败: ~a (~a ~a)~%"
                                           name key args)
                                   #f)))
                             %all-modules)))
                 (let ((text (get-output-string warnings)))
                   (when (string-contains text "unbound")
                     (format (current-error-port) "~a" text))
                   (and ok (not (string-contains text "unbound")))))))

;; operating-system 的 services 等字段是延迟求值的，compile-file 不会
;; 触发字段校验；这里显式实例化 %os，让“services 字段必须是服务列表”
;; 这类错误在测试期暴露，而不是留到 system build。
(test-assert "hosts/vm.scm 的 %os 可实例化（services 字段合法）"
             (let ((os (module-ref (resolve-module '(guixcfg hosts vm)) '%os)))
               (list? ((@ (gnu system) operating-system-services) os))))

(test-end)
