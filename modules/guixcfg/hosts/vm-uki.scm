;;; VM（UKI 变体）最终 <operating-system> 组装点。
;;; 与 (guixcfg hosts vm) 的唯一区别是 bootloader：GRUB-EFI 换成
;;; UKI + UEFI 直启（docs/boot.md 第 16 章；systemd-boot 待 Rosenthal
;;; 提供后再接入）。GRUB 的 vm host 保留作开发/救援对照。
;;;
;;; 构建：GUIX_CONFIG_FACTS=... guix time-machine -C channels.lock.scm \
;;;         -- system build -L modules modules/guixcfg/hosts/vm-uki.scm

(define-module (guixcfg hosts vm-uki)
               #:use-module (gnu)              ; operating-system、bootloader-configuration
               #:use-module (guixcfg boot uki-bootloader)  ; uki-bootloader
               #:use-module (guixcfg hosts vm)             ; 复用 vm 的 %os
               #:export (%os))

(define %os
  (operating-system
   (inherit (@ (guixcfg hosts vm) %os))
   (bootloader (bootloader-configuration
                (bootloader uki-bootloader)
                (targets '("/efi"))))))

;; 末尾裸表达式：本文件同时是 guix system 的入口文件（daviwil 模式）。
%os
