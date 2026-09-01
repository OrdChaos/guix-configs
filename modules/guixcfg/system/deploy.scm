;;; 部署编排的纯 helper 层（Blue Phase 1）。
;;;
;;; 职责边界（设计决策记录）:
;;;   - 只构造 argv / 解析命令输出 / 提供只读检查素材 / 枚举与校验
;;;     host ID；
;;;   - 不执行任何子进程（blueprint 的 %run 是唯一执行出口）；
;;;   - 不实现 gate/herd/Home pivot 事务——(guixcfg system reconfigure)
;;;     是事务机制事实源；
;;;   - 不复制 facts resolver（复用 (guixcfg system machine-facts)）；
;;;   - 不持有 host 清单——host ID 事实来自 modules/guixcfg/hosts/*.scm
;;;     的文件名 stem（目录枚举；新增 host 文件自动进入枚举；
;;;     helper 文件经 %host-helper-file-stems 显式排除——
;;;     hosts/common.scm 的共享组装算法不参与枚举）。
;;;
;;; 纯函数化的目的是让 tests/test-deploy.scm 在不跑真实 guix 的情况下
;;; 断言 argv 形态：pinned channels.lock.scm、绝对 -L、dry-run 语义、
;;; sudo 边界（privilege handoff 用同一个 Blue executable）、
;;; reconfigure -n 不进入 privileged transaction。

(define-module (guixcfg system deploy)
               #:use-module (guixcfg utils repository-source) ; repository-root（marker-based 统一解析）
               #:use-module (guixcfg utils channels)
               #:use-module (guixcfg system machine-facts)
               #:use-module (ice-9 ftw)     ; scandir
               #:use-module (ice-9 format)
               #:use-module (srfi srfi-1)
               #:export (%hosts-directory
                         host-ids-in-directory
                         host-source-relative-path
                         host-source-absolute-path
                         host-id?
                         require-host-id
                         guix-time-machine-argv
                         system-build-argv
                         system-reconfigure-argv
                         system-reconfigure-dry-run-argv
                         reconfigure-privileged-argv
                         channel-lock-refresh-argv
                         git-status-porcelain-argv
                         git-head-commit-argv
                         porcelain-output-clean?
                         trimmed-command-output
                         known-host-ids
                         channels-structure-ok?
                         facts-resolution-report
                         %boot-critical-facts))

(define %channels-file "channels.scm")
(define %channels-lock-file "channels.lock.scm")
(define %modules-dir "modules")

;; privileged 模式（sudo 后 root 进程）的 Blue store 位置。与
;; (guixcfg system session-gate) 的 %session-gate-directory
;; （/run/guixcfg）同根：项目在 /run 的 privileged 运行时命名空间，
;; root 所有、tmpfs、重启即清。
(define %privileged-blue-store "/run/guixcfg/.blue-store")

;;; ---------- host ID 枚举与校验 ----------

;; 仓库根相对目录（唯一拼写处）；调用方负责解析仓库根。
(define %hosts-directory "modules/guixcfg/hosts")

;; hosts/ 下的 helper 文件 stem（非 host 入口）——枚举显式排除。
;; hosts/common.scm 是 VM/Laptop 的共享 composition algorithm：
;; 目录枚举把每个 .scm 的 stem 当 host ID，helper 必须在此登记
;; （否则会被误判为 host "common"）。
(define %host-helper-file-stems
  '("common"))

(define (host-candidate-file? name)
  "NAME 是否可作为 host ID 源文件：.scm 后缀，且非 dot 文件、非 ~ 备份、
非 #…# autosave，且 stem 不在 %host-helper-file-stems。"
  (let ((stem (and (string-suffix? ".scm" name)
                   (substring name 0 (- (string-length name) 4)))))
    (and stem
         (not (string-prefix? "." name))
         (not (string-suffix? "~" name))
         (not (and (string-prefix? "#" name) (string-suffix? "#" name)))
         (not (member stem %host-helper-file-stems)))))

(define (host-ids-in-directory dir)
  "DIR 下全部 host ID（排序）。DIR 不存在时由 scandir 报错（fail
closed，不静默返回空表）。"
  (sort (map (lambda (f) (substring f 0 (- (string-length f) 4)))
             (filter host-candidate-file?
                     (scandir dir)))
        string<?))

(define (host-source-relative-path id)
  "HOST ID 的仓库根相对配置入口（传给 guix 的 host 文件路径）。"
  (string-append %hosts-directory "/" id ".scm"))

(define (host-source-absolute-path root id)
  "HOST ID 配置入口的绝对路径。"
  (string-append root "/" (host-source-relative-path id)))

(define (host-id? ids id)
  "ID 是否在已知 host ID 集合 IDS 中。"
  (and (string? id) (member id ids)))

(define (require-host-id ids id)
  "ID 必须已知，否则报错并列出可用 host（fail closed，绝不 fallback）。"
  (if (host-id? ids id)
    id
    (error (string-append "unknown host: " id "\n"
                          "known hosts: " (string-join ids ", ") "\n"
                          "usage: blue <command> HOST"))))

;;; ---------- argv 构造（纯函数） ----------

(define (guix-time-machine-argv root channels-file subcommand)
  "构造锁定频道的 guix 命令 argv。ROOT 必须为绝对路径；CHANNELS-FILE
是仓库根相对文件名；SUBCOMMAND 是 time-machine -- 之后的参数列表。"
  `("guix" "time-machine" "-C" ,(string-append root "/" channels-file)
           "--" ,@subcommand))

(define (system-subcommand-argv root host action extra)
  "guix system 子命令 argv：-L 必须是绝对路径（AGENT.md：source-relative
local-file 在相对 load-path 下 lowering 阶段解析失败），host 文件按
host-source-relative-path 的权威相对路径。"
  `("system" ,action ,@extra
              "-L" ,(string-append root "/" %modules-dir)
              ,(host-source-relative-path host)))

(define* (system-build-argv root host #:key dry-run?)
         ;; blue build-os 的 argv；dry-run? 时映射为下游 guix system build
         ;; --dry-run（不构建 store object，输出 derivation/build plan）。
         (guix-time-machine-argv root %channels-lock-file
                                 (system-subcommand-argv root host "build"
                                                         (if dry-run? '("--dry-run") '()))))

(define (system-reconfigure-argv root host)
  ;; blue reconfigure 的 root phase 实际执行的 guix argv（无
  ;; --dry-run）——(guixcfg system reconfigure) 事务的核心子进程。
  (guix-time-machine-argv root %channels-lock-file
                          (system-subcommand-argv root host "reconfigure" '())))

(define (system-reconfigure-dry-run-argv root host)
  ;; blue -n reconfigure 的 argv：直接 guix system reconfigure --dry-run
  ;; （验证 system derivation/build plan），绝不进入 privileged
  ;; transaction（gate/herd/Home 热激活不参与 dry-run）。
  (guix-time-machine-argv root %channels-lock-file
                          (system-subcommand-argv root host "reconfigure" '("--dry-run"))))

(define (reconfigure-privileged-argv blue-executable blueprint-path host home-user)
  ;; blue reconfigure 的 privilege handoff argv：sudo 重新执行【同一
  ;; 个】Blue executable（绝对路径，绝不依赖 root PATH 重新查找），
  ;; -f 显式指定仓库 blueprint.scm，内部模式 .reconfigure-root 分项
  ;; 传递 HOST 与 HOME_USER。
  ;;
  ;; --store-directory 把 root 进程的 Blue store 指到
  ;; /run/guixcfg/.blue-store：sudo 继承调用者 cwd，若沿用默认
  ;; store（cwd/.blue-store）会在用户仓库里留下 root 所有的
  ;; .lock / local-compile .go，之后普通用户运行 blue 会报权限
  ;; 不足（make-store 每次启动都要以写模式打开 .lock）。
  ;; argv 列表，无 shell 拼接。
  `("sudo" ,blue-executable
            ,(string-append "--store-directory=" %privileged-blue-store)
            "-f" ,blueprint-path
            ".reconfigure-root" ,host ,home-user))

(define (channel-lock-refresh-argv root)
  ;; blue update 的 argv：channels.scm:6-9 的文档化流程——用可变频道
  ;; 定义 describe 并重写锁。不 build、不 deploy、不 commit。
  `("guix" "time-machine" "-C" ,(string-append root "/" %channels-file)
           "--" "describe" "-f" "channels"))

(define (git-status-porcelain-argv root)
  `("git" "-C" ,root "status" "--porcelain"))

(define (git-head-commit-argv root)
  `("git" "-C" ,root "rev-parse" "HEAD"))

;;; ---------- 命令输出解析（纯函数） ----------

(define (porcelain-output-clean? output)
  "git status --porcelain 输出为空 = 工作树干净。"
  (string-null? (string-trim-both output)))

(define (trimmed-command-output output)
  (string-trim-both output))

;;; ---------- 只读检查素材 ----------

(define (known-host-ids root)
  (host-ids-in-directory (string-append root "/" %hosts-directory)))

(define (channels-structure-ok? root)
  "channels.scm 与 channels.lock.scm 结构兼容（name/url/branch/
introduction；不比较 revision）。文件缺失/不可读时报错。"
  (channel-declaration-sets-compatible?
   (read-channel-declarations (string-append root "/" %channels-file))
   (read-channel-declarations (string-append root "/" %channels-lock-file))))

;; boot-critical facts 的权威调用方是 file-systems.scm 的
;; cryptroot-mapped-devices（require-machine-fact 'luks-uuid）——若该
;; 调用方增长，本表必须同步。doctor 只做文件级 fail-closed 验证，
;; 完整 lowering 验证是 build-os -n 的职责。
(define %boot-critical-facts '(luks-uuid))

(define (facts-resolution-report)
  "复用 (guixcfg system machine-facts) 的 resolution policy（单一事实源），
返回 '(ok . facts) / '(none) / '(invalid . message)。任何解析/校验错误
都收敛为 'invalid（doctor 只报告检查失败，不抛异常打断其余检查）。"
  (catch #t
    (lambda ()
      (let ((path (resolve-facts-path (getenv "GUIX_CONFIG_FACTS")
                                      %default-machine-facts-path)))
        (if path
          (let ((facts (load-machine-facts path)))
            (if (every (lambda (key) (and (assq key facts) #t))
                       %boot-critical-facts)
              (cons 'ok facts)
              (cons 'invalid
                    (format #f "facts file ~a lacks boot-critical facts: ~a"
                            path %boot-critical-facts))))
          '(none))))
    (lambda (key . args)
      (cons 'invalid
            (format #f "facts resolution failed: ~s ~s" key args)))))
