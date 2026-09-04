;;; System-owned /etc/profile（POSIX login shell 的 system-wide 环境）。
;;;
;;; Ownership（2026-09 登录链审计决策，docs/architecture 登录链）：
;;;
;;;   唯一 owner：Guix Home 环境激活 = home 自己
;;;     ~/.profile → setup-environment（home-environment-variables-
;;;     service-type 生成；pinned gnu/home/services.scm 明确"expected
;;;     to be sourced by login shell"）——它 source 一次
;;;     ~/.guix-home/profile/etc/profile 并追加 env-var exports。
;;;   唯一 owner：system /etc/profile = 本模块
;;;     system profile 激活 + 用户 ~/.guix-profile /
;;;     ~/.config/guix/current 的 etc/profile 激活 + privileged
;;;     PATH + /etc/environment + DICPATH + umask。pinned guix 模板
;;;     的 user-profile loop 里包含 $HOME/.guix-home/profile 条目
;;;     ——同一 login shell 里它与 setup-environment 各 source 一次
;;;     guix-home 的 etc/profile；该文件对 XDG_DATA_DIRS/PATH 等
;;;     做【无守卫】prepend，home profile share 在环境里出现两份，
;;;     逐目录扫描 XDG_DATA_DIRS 的消费者（nautilus-python loader
;;;     每目录实例化 provider）重复注册（2026-09 VM 实测：右键
;;;     菜单重复项）。
;;;
;;;   修复 = 删除错误的第二 source：本模块的 /etc/profile 与
;;;   pinned guix 模板逐字一致，唯删除 loop 里的 guix-home 条目
;;;   （静态文件 colocate：同目录 profile）。不做任何运行时去重
;;;   兜底——source 拓扑本身无重复。
;;;
;;;   非交互上下文（不读 ~/.profile 的 SSH 命令等）对 home 环境的
;;;   影响以 VM 验收实测为准（2026-09）。

(define-module (guixcfg system profile policy)
               #:use-module (gnu services) ; etc-service-type
               #:use-module (guix gexp)    ; local-file
               #:use-module (srfi srfi-1)  ; remove
               #:export (%system-profile
                         system-profile-etc-entries))

(define %system-profile
  (local-file "profile" "system-profile"))

(define (system-profile-etc-entries entries)
  "etc-service-type 的 value 变换：移除上游 'profile 条目，追加
  本仓库拥有的 /etc/profile（删除 guix-home loop 条目，见文件头）。"
  (append (remove (lambda (entry)
                    (string=? "profile" (car entry)))
                  entries)
          `(("profile" ,%system-profile))))
