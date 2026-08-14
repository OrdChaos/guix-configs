;;; T3 集成测试专用 host：正常 VM（(guixcfg hosts vm)）+ 测试增强。
;;;
;;; 职责边界：正常 VM target 由 modules/guixcfg/hosts/vm.scm 描述；本模块
;;; 只做 T3 测试需要的增强（composition，不复制 %os）：
;;;   - root 测试账号（t3-root-password，仅测试环境）
;;;   - ttyS0 串口自动登录（harness 串口交互）
;;;   - SSH（harness 经 hostfwd 2222→22 执行系统内命令）
;;;   - guix / tpm2-tools-compat（VM 内运行 enroll 与 PCR7 读取）
;;;
;;; SSH 公钥由 tests/integration/t3/run.sh 在 fresh workspace 生成
;;; （vms/t3/ssh/，gitignored runtime），不依赖 developer home path。
;;;
;;; 模块名 (integration t3 host)：-L tests 加载；文件末尾 %t3-os 裸表达式
;;; 同时让它成为 guix system 的入口文件（同 hosts/vm.scm 模式）。

(define-module (integration t3 host)
               #:use-module (gnu)                          ; operating-system 等
               #:use-module (gnu services base)            ; agetty-service-type、agetty-configuration
               #:use-module (gnu services ssh)             ; openssh-service-type、openssh-configuration
               #:use-module (gnu packages bash)            ; bash
               #:use-module (gnu packages package-management) ; guix
               #:use-module (virelith packages tpm2)       ; tpm2-tools-compat
               #:use-module (guix gexp)                    ; local-file
               #:use-module ((guixcfg hosts vm) #:prefix vm:) ; %os
               #:export (%t3-os))

;; T3 测试 root 账号。密码哈希对应 t3-root-password（仅测试环境；
;; 测试凭据只存在于 tests/integration/t3，不进正常 VM host）。
(define %t3-root
  (user-account
   (name "root")
   (comment "T3 test root")
   (group "root")
   (shell (file-append bash "/bin/bash"))
   (home-directory "/root")
   (password "$6$PLZmfXnlX.NPoslT$8l/LjqcwElCDRi7oRnyp13NKV1LY83jJNl.sLwIfzhHh/xyst9XH05QiGYA1Uyc15vQ9dzyneq2YKKignmMMd1")))

;; T3 harness SSH 公钥：run.sh 生成（fresh workspace）。
;; local-file 相对本文件解析：tests/integration/t3 → 仓库根 → vms/t3/ssh。
(define %t3-ssh-pubkey
  (local-file "../../../vms/t3/ssh/id_ed25519.pub"))

(define %t3-extra-services
  (list
   ;; ttyS0 串口登录（T3 harness 经串口交互；root 自动登录仅测试）。
   ;; agetty 显式占用后 %base-services 内置的自动探测会跳过 ttyS0
   ;; （实测 mingetty 与自动探测竞争会导致会话被杀）。
   (service agetty-service-type
            (agetty-configuration
             (tty "ttyS0")
             (term "vt100")
             (auto-login "root")))
   ;; SSH（T3 harness 经 hostfwd 2222→22 执行系统内命令——串口 getty
   ;; 会话在注入输入时不稳定，实测）；root 登录仅测试环境。
   (service openssh-service-type
            (openssh-configuration
             (permit-root-login #t)
             (authorized-keys
              `(("root" ,%t3-ssh-pubkey)))))))

(define %t3-os
  (operating-system
   (inherit vm:%os)
   (users (cons %t3-root (operating-system-users vm:%os)))
   (packages (append (list guix tpm2-tools-compat)
                     (operating-system-packages vm:%os)))
   ;; 基础服务用 vm 的显式 services 字段（%vm-services）——不含
   ;; operating-system-services 自动生成的 account/shepherd-root
   ;; （本 OS 的 users 与实例化会各自生成唯一实例）。
   (services (append vm:%vm-services %t3-extra-services))))

;; 末尾裸表达式：guix system init/reconfigure 加载本文件时取此值。
%t3-os
