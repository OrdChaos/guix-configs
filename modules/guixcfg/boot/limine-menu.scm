;;; Limine 菜单文本生成（纯函数；无 Guix channel 依赖——部署脚本可
;;; 直接加载本模块，不会拖入 rosenthal 等 boot 闭包）。
;;;
;;; 公开 boot model 只有两个用户可选启动项：
;;;   Normal   （GNU Guix，CURRENT.EFI，rootmode 缺省 = normal）
;;;   Recovery （GNU Guix (Recovery)，RECOVERY.EFI，rootmode=recovery；
;;;             只有 promote 后（文件就位）才出现在菜单）
;;; 历史 @root 不作为菜单项（previous:K 菜单与 PREV-K.EFI 已删除）。

(define-module (guixcfg boot limine-menu)
               #:use-module (ice-9 format)
               #:use-module (ice-9 textual-ports) ; call-with-output-string
               #:export (limine-config-text))

(define (limine-config-text target-slot recovery-present?)
  "生成 Limine 配置文本：Normal（指向 TARGET-SLOT 的 CURRENT.EFI）+
Recovery（指向稳定路径 RECOVERY.EFI；RECOVERY-PRESENT? 为 #f 时不
输出）。返回字符串。"
  (call-with-output-string
   (lambda (port)
     (format port "\
timeout: 3

/GNU Guix
    protocol: efi_chainload
    image_path: boot():/EFI/Guix/~a/CURRENT.EFI
" target-slot)
     (when recovery-present?
       (format port "\
/GNU Guix (Recovery)
    protocol: efi_chainload
    image_path: boot():/EFI/Guix/RECOVERY.EFI
")))))
