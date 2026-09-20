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
;;; sudo 边界（privilege handoff 直接进入 pinned CLI）、
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
                         modules-load-path-env
                         guix-time-machine-argv
                         system-build-argv
                         system-reconfigure-argv
                         system-reconfigure-dry-run-argv
                         system-init-argv
                         reconfigure-privileged-argv
                          install-privileged-argv
                          enroll-privileged-argv
                          gc-privileged-argv
                          install-cli-argv
                          install-success-cleanup-commands
                          enroll-cli-argv
                         gc-cli-argv
                         sb-keygen-tool-argv
                         sb-keystore-tool-argv
                         commit-root-tool-argv
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

;; 库模块经 GUILE_LOAD_PATH/GUILE_LOAD_COMPILED_PATH 注入子进程，绝不
;; 用 -L：-L/--load-path 会把 modules/ 加进「包搜索路径」
;; （%package-module-path），guix system 的 fold-packages 会遍历并加载
;; 其中每个 .scm（含非模块的 gsettings/runtime.scm 与 OS 入口文件），
;; 污染模块缓存——实测导致 %applications/%guix-home 未绑定。GUILE_LOAD_PATH
;; 只影响 Guile 的 %load-path，包发现不遍历（对齐 alezost/guix-config 的
;; 做法：GUIX_PACKAGE_PATH 只放包，其余模块走 GUILE_LOAD_PATH）。
(define (modules-load-path-env root)
  "env(1) argv 前缀：把 ROOT/modules 注入子进程的
GUILE_LOAD_PATH/GUILE_LOAD_COMPILED_PATH。"
  `("env"
    ,(string-append "GUILE_LOAD_PATH=" root "/" %modules-dir)
     ,(string-append "GUILE_LOAD_COMPILED_PATH=" root "/" %modules-dir)))

(define (guix-time-machine-argv root channels-file subcommand)
  "构造锁定频道的 guix 命令 argv（前缀注入 modules load path env）。
ROOT 必须为绝对路径；CHANNELS-FILE 是仓库根相对文件名；SUBCOMMAND
是 time-machine -- 之后的参数列表。"
  (append (modules-load-path-env root)
          `("guix" "time-machine" "-C" ,(string-append root "/" channels-file)
                   "--" ,@subcommand)))

(define (system-subcommand-argv root host action extra)
  "guix system 子命令 argv：host 文件按 host-source-relative-path 的
权威相对路径；库模块经 guix-time-machine-argv 的 GUILE_LOAD_PATH 注入
（不用 -L，见 modules-load-path-env）。"
  `("system" ,action ,@extra
              ,(host-source-relative-path host)))

(define* (system-build-argv root host #:key dry-run?)
         ;; blue build-os 的 argv；dry-run? 时映射为下游 guix system build
         ;; --dry-run（不构建 store object，输出 derivation/build plan）。
         (guix-time-machine-argv root %channels-lock-file
                                 (system-subcommand-argv root host "build"
                                                         (if dry-run? '("--dry-run") '()))))

;; reconfigure 的 guix 选项：--no-kexec 关闭 pinned guix 默认开启的
;; kexec 预载（reconfigure 完成时用 kexec_file_load 把新 kernel/initrd
;; 装进内存，供 `reboot --kexec` 免固件重启）。本系统不需要该步骤，
;; 且它要打开新 kernel/initrd。gnu/system.scm 无声明式开关，只能传
;; CLI flag（pinned guix 的 load-for-kexec? 默认 #t）。
(define %reconfigure-options '("--no-kexec"))

(define (system-reconfigure-argv root host)
  ;; blue reconfigure 的 root phase 实际执行的 guix argv（无
  ;; --dry-run）——(guixcfg system reconfigure) 事务的核心子进程。
  (guix-time-machine-argv root %channels-lock-file
                          (system-subcommand-argv root host "reconfigure"
                                                  %reconfigure-options)))

(define (system-reconfigure-dry-run-argv root host)
  ;; blue -n reconfigure 的 argv：直接 guix system reconfigure --dry-run
  ;; （验证 system derivation/build plan），绝不进入 privileged
  ;; transaction（gate/herd/Home 热激活不参与 dry-run）。选项与真实
  ;; reconfigure 保持一致（--dry-run 下 --no-kexec 无副作用，仅让预览
  ;; 与真实 argv 同形）。
  (guix-time-machine-argv root %channels-lock-file
                          (system-subcommand-argv root host "reconfigure"
                                                  (cons "--dry-run"
                                                        %reconfigure-options))))

(define (system-init-argv root host)
  ;; blue install 的 guix system init argv：pinned channels.lock.scm、
  ;; 显式 host 文件、目标 /mnt（库模块经 GUILE_LOAD_PATH 注入，不用
  ;; -L，见 modules-load-path-env）。guix system init 的语法是
  ;; FILE 在选项之后、TARGET 最后——/mnt 必须放末尾（放前面会被当
  ;; 成 FILE：failed to load '/mnt': Is a directory，VM 实测）。
  ;; 调用方负责已挂好 /mnt 并设置 GUIX_CONFIG_FACTS。
  (guix-time-machine-argv root %channels-lock-file
                          `("system" "init"
                                     ,(host-source-relative-path host)
                                     "/mnt")))

(define (reconfigure-privileged-argv root host home-user)
  ;; root phase 直接进入 pinned CLI，不重新编译整份 blueprint。sudo 会
  ;; 重置 HOME，root Blue 无法解析用户 guix current 的 channel modules；
  ;; 冷 privileged Blue store 还会触发 Guile linker out-of-range。事务
  ;; authority 仍是 (guixcfg system reconfigure)，此处只构造 argv。
  (cons "sudo"
        (guix-time-machine-argv
         root %channels-lock-file
         `("repl" ,(string-append root "/tools/reconfigure-cli.scm")
                   "--" ,host ,home-user))))

(define (install-privileged-argv root host device)
  ;; root phase 直接进入 pinned install CLI；确认 UI、事务与成功清理均由
  ;; tools/install-cli.scm 持有，不重新编译整份 blueprint。
  (cons "sudo" (install-cli-argv root "run" host device)))

(define (enroll-privileged-argv root host)
  ;; HOST 显式传递，绝不自动检测；root phase 直接进入 pinned CLI。
  (cons "sudo" (enroll-cli-argv root "run" host)))

(define (gc-privileged-argv root host extra)
  ;; 删除 system generation 需要写 /var/guix/profiles；EXTRA 是
  ;; ("--keep" "N") / ("--delete" "LIST") / '() 透传。
  (cons "sudo" (gc-cli-argv root "run" host extra)))

(define (install-cli-argv root mode host device)
  ;; blue install 的 pinned 执行入口 argv（tools/install-cli.scm）：
  ;; 域执行在子进程（blueprint 进程内加载大模块图会 link 阶段
  ;; out-of-range——gsettings 同款决策）。MODE ∈ plan | run。
  ;; time-machine repl 自带全部频道模块 load path，工具自行加入
  ;; 仓库 modules/（从仓库根运行）。
  (guix-time-machine-argv root %channels-lock-file
                           `("repl" "tools/install-cli.scm" "--"
                                    ,mode ,host ,device)))

(define (install-success-cleanup-commands)
  "安装完整 validate 成功后、返回 installer shell 前的 root 清理 argv。
只停止 install-time cow-store 并落盘；刻意不 unmount、不 poweroff、
不 reboot。"
  '(("herd" "stop" "cow-store")
    ("sync")))

(define (enroll-cli-argv root mode host)
  ;; blue enroll 的 pinned 执行入口 argv（tools/enroll-cli.scm）。
  (guix-time-machine-argv root %channels-lock-file
                          `("repl" "tools/enroll-cli.scm" "--"
                                   ,mode ,host)))

(define (gc-cli-argv root mode host extra)
  ;; blue gc 的 pinned 执行入口 argv（tools/gc-cli.scm）：域执行在
  ;; 子进程（blueprint 编译期不导入 system-generations，gsettings/
  ;; install/enroll 同款决策）。MODE ∈ plan | run；EXTRA 透传
  ;; ("--keep" "N") / ("--delete" "LIST")。
  (guix-time-machine-argv root %channels-lock-file
                          `("repl" "tools/gc-cli.scm" "--"
                                   ,mode ,host ,@extra)))

(define (sb-keygen-tool-argv root keydir)
  ;; tools/secure-boot-keygen.scm 的官方调用形态（工具头部注释）：
  ;; pinned shell + keygen manifest 提供 ukify，guix repl 执行工具。
  ;; 工具自身不带 load path；模块经 GUILE_LOAD_PATH 注入（不用 -L，
  ;; 见 modules-load-path-env）。
  (guix-time-machine-argv root %channels-lock-file
                          `("shell" "-m" "manifests/secure-boot-keygen.scm"
                                    "--" "guix" "repl"
                                    "tools/secure-boot-keygen.scm" ,keydir)))

(define (sb-keystore-tool-argv root keydir)
  ;; tools/secure-boot-enroll.scm 的官方调用形态（工具头部注释）：
  ;; 构建 sbkeysync keystore（不写固件；固件写入归 blue enroll）。
  ;; 外层 shell 提供 efitools/sbsigntools/openssl 二进制；内层用
  ;; pinned repl（非 guix repl——工具 import (virelith packages
  ;; secure-boot)，宿主 guix current 无频道模块时会
  ;; no code for module，VM 实测）。模块经 GUILE_LOAD_PATH 注入。
  (guix-time-machine-argv root %channels-lock-file
                          `("shell" "-m" "manifests/secure-boot-enroll.scm"
                                    "--" "guix" "time-machine" "-C"
                                    ,(string-append root "/" %channels-lock-file)
                                    "--" "repl"
                                    "tools/secure-boot-enroll.scm" ,keydir)))

(define (commit-root-tool-argv root target)
  ;; tools/disk-install.scm 的 commit-root 子命令（安装阶段的 root
  ;; 提交走独立子进程：commit-root-generation 失败时是硬 exit，
  ;; 子进程隔离才能做退出码分类——(guixcfg system install)）。
  (guix-time-machine-argv root %channels-lock-file
                          `("repl" "tools/disk-install.scm" "--"
                                   "commit-root" ,target)))

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
