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

;; 依赖顺序排列：被依赖的模块先编译注册。
;; 注意：依赖缺失时 compile-file 报 "no code for module"（冷 ccache
;; 下必现——不要依赖热缓存掩盖顺序错误；实测基线把 utils/process
;; 排在 storage/filesystem 之后是潜在 bug）。
;; 依赖顺序排列：被依赖的模块先编译注册（完整清单，2026-08 由
;; modules/guixcfg 全量扫描 + guixcfg import 拓扑排序生成；冷 ccache
;; 下 compile-file 对依赖缺失报 "no code for module"——不要依赖热缓存
;; 掩盖顺序错误，也不许手工漏模块）。
;; 依赖顺序排列：被依赖的模块先编译注册（完整清单，2026-08 由
;; modules/guixcfg 全量扫描 + #:use-module 行拓扑排序生成；冷 ccache
;; 下 compile-file 对依赖缺失报 "no code for module"——不要依赖热缓存
;; 掩盖顺序错误，也不许手工漏模块）。
;; 依赖顺序排列：被依赖的模块先编译注册（完整清单，2026-08 由
;; modules/guixcfg 全量扫描 + #:use-module 行拓扑排序生成；冷 ccache
;; 下 compile-file 对依赖缺失报 "no code for module"——不要依赖热缓存
;; 掩盖顺序错误，也不许手工漏模块）。
(define %all-modules
  '(    (guixcfg apps model)
    (guixcfg apps bash definition)
    (guixcfg apps curl definition)
    (guixcfg apps dbus definition)
    (guixcfg apps fd definition)
    (guixcfg apps file definition)
    (guixcfg apps ghostty definition)
    (guixcfg apps fuzzel definition)
    (guixcfg apps git definition)
    (guixcfg apps jq definition)
    (guixcfg apps less definition)
    (guixcfg apps mako definition)
    (guixcfg storage model)
    (guixcfg system application-persistence)
    (guixcfg security secrets)     ; gnome-keyring definition 的依赖（topological）
    (guixcfg users user)           ; gnome-keyring definition 的依赖（topological）
    (guixcfg apps gnome-keyring definition)
    (guixcfg apps google-chrome-stable definition)
    (guixcfg apps mpv definition)
    (guixcfg apps niri definition)
    (guixcfg apps pipewire definition)
    (guixcfg apps polkit-gnome definition)
    (guixcfg apps ripgrep definition)
    (guixcfg apps tree definition)
    (guixcfg apps wget definition)
    (guixcfg apps wl-clipboard definition)
    (guixcfg apps zip definition)
    (guixcfg apps registry)
    (guixcfg utils atomic-file)
    (guixcfg boot boot-state)
    (guixcfg boot device-resolver)
    (guixcfg utils spawn)
    (guixcfg security tpm2 tpm2-tools)
    (guixcfg boot tpm-unlock)
    (guixcfg storage root-generation)
    (guixcfg boot initrd)
    (guixcfg boot limine-menu)
    (guixcfg boot recovery)
    (guixcfg boot uki)
    (guixcfg boot uki-bootloader)
    (guixcfg home fonts)
    (guixcfg home xdg)
    (guixcfg home pivot)
    (guixcfg home user)
    (guixcfg storage policies)
    (guixcfg hosts laptop)
    (guixcfg utils process)
    (guixcfg security age)
    (guixcfg utils repository-source)
    (guixcfg hosts vm-secrets)
    (guixcfg services ephemeral-root)
    (guixcfg system accounts)
    (guixcfg system substitutes)
    (guixcfg system common)
    (guixcfg system desktop)
    (guixcfg system file-systems)
    (guixcfg system kernel-platform)
    (guixcfg system packages)
    (guixcfg system readiness)
    (guixcfg system ssh)
    (guixcfg system user-persistence)
    (guixcfg hosts vm)
    (guixcfg security certificates)
    (guixcfg storage validate)
    (guixcfg storage device)
    (guixcfg storage partition)
    (guixcfg storage filesystem)
    (guixcfg storage plan)
    (guixcfg storage subvolume)
    (guixcfg storage install)
    (guixcfg security credential-source)
    (guixcfg security tpm2 state)
    (guixcfg storage commit)
    (guixcfg system machine-state-persistence)
    (guixcfg system graphics nvidia)))

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
;; 触发字段校验；这里显式实例化 %os，让“services 字段必须是服务列表”
;; 这类错误在测试期暴露，而不是留到 system build。
(test-assert "hosts/vm.scm %os instantiates (valid services field)"
             (let ((os (module-ref (resolve-module '(guixcfg hosts vm)) '%os)))
               (list? ((@ (gnu system) operating-system-services) os))))

(test-end)
