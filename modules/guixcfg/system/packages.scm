;;; 系统级软件：所有用户都需要的基础工具（docs/system.md 第 23.1 节）。
;;; 服务自己依赖的软件由 service 直接引用，不放在这里。

(define-module (guixcfg system packages)
               #:use-module (gnu system)                  ; %base-packages
               #:use-module (gnu packages linux)          ; btrfs-progs（当前 master 在此导出）
               #:use-module (gnu packages cryptsetup)     ; cryptsetup
               #:use-module (gnu packages golang-crypto)  ; age
               #:export (%system-packages))

(define %system-packages
  (append (list btrfs-progs       ; 子卷/快照管理（恢复时必需）
                cryptsetup        ; LUKS 维护（恢复时必需）
                age)              ; secrets 解密（guixcfg-secrets-deploy
                                  ; 与 password-inject 的运行时依赖）
          %base-packages))
