;;; Boot/ESP artifact 布局的固定事实（纯数据，零依赖）。
;;;
;;; 本模块是同一份布局契约在三类执行环境间的唯一 authority：
;;;   - config 侧（部署脚本生成：(guixcfg boot uki)、file-systems）
;;;   - initrd 运行时（(guixcfg boot tpm-unlock)——闭包经
;;;     source-module-closure 传递带入，纯字符串定义无运行时依赖）
;;;   - 用户态工具（tools/tpm2-enroll.scm、storage/commit.scm、
;;;     services/ephemeral-root.scm）
;;; 禁止各层重复拼写字面量（AGENT.md §13；invariants §1）——尤其
;;; %esp-tpm2-directory 是 enrollment（写）与 initrd 解锁（读）的
;;; 跨进程契约，漂移会让 TPM 自动解锁静默失效（回退密码）。

(define-module (guixcfg boot layout)
               #:export (%esp-mount-point
                         %esp-uki-directory
                         %esp-tpm2-directory
                         %recovery-uki-esp-path
                         %uki-deploy-script-path))

;; ESP（EFI system partition）在运行系统上的固定挂载点。
(define %esp-mount-point "/efi")

;; ESP 上 UKI deployment 的根目录（ESP 相对路径，不带前导 /）：
;;   EFI/Guix/{A,B}/       完整 deployment 槽
;;   EFI/Guix/.deployed    所有权清单
;;   EFI/Guix/candidate.scm Recovery candidate 元数据
(define %esp-uki-directory "EFI/Guix")

;; TPM2 sealed artifact 的 ESP 目录（ESP 相对）：解锁 LUKS 前必须可读，
;; 不能只放 /persist（循环依赖）；非秘密（篡改只造成 DoS → 密码回退）。
(define %esp-tpm2-directory "EFI/Guix/tpm2")

;; 正式 Recovery UKI 的 ESP 稳定路径（ESP 相对；promote 后菜单才出现）。
(define %recovery-uki-esp-path "EFI/Guix/RECOVERY.EFI")

;; UKI 部署脚本在目标系统 root 上的落点（install-boot-config 复制到这里；
;;; commit-root 在提交后执行它）。
(define %uki-deploy-script-path "/boot/deploy-uki")
