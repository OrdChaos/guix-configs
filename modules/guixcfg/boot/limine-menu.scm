;;; Limine 菜单文本生成（纯函数；无 Guix channel 依赖——部署脚本可
;;; 直接加载本模块，不会拖入 rosenthal 等 boot 闭包；(guixcfg boot
;;; layout) 是纯常量）。
;;;
;;; 公开 boot model 只有两个用户可选启动项：
;;;   Normal   （GNU Guix，CURRENT.EFI，rootmode 缺省 = normal）
;;;   Recovery （GNU Guix (Recovery)，RECOVERY.EFI，rootmode=recovery；
;;;             只有 promote 后（文件就位）才出现在菜单）
;;; 历史 @root 不作为菜单项（previous:K 菜单与 PREV-K.EFI 已删除）。

(define-module (guixcfg boot limine-menu)
               #:use-module (guixcfg boot layout)  ; ESP 布局固定事实
               #:use-module (ice-9 format)
               #:use-module (ice-9 textual-ports) ; call-with-output-string
               #:export (limine-config-text
                         recovery-menu-entry-text))

(define (recovery-menu-entry-text)
  "Recovery 菜单条目文本（指向 ESP 稳定路径）。初始生成
（limine-config-text）与 promote 时追加（(guixcfg boot recovery)）
共用同一来源——两处不得各自拼写。"
  (string-append "/GNU Guix (Recovery)\n"
                 "    protocol: efi_chainload\n"
                 "    image_path: boot():/" %recovery-uki-esp-path "\n"))

(define (limine-config-text target-slot recovery-present?)
  "生成 Limine 配置文本：Normal（指向 TARGET-SLOT 的 CURRENT.EFI）+
Recovery（RECOVERY-PRESENT? 为 #f 时不输出）。返回字符串。"
  (call-with-output-string
   (lambda (port)
     (format port "\
timeout: 3

/GNU Guix
    protocol: efi_chainload
    image_path: boot():/~a/~a/CURRENT.EFI
" %esp-uki-directory target-slot)
     (when recovery-present?
       (format port "\n~a" (recovery-menu-entry-text))))))
