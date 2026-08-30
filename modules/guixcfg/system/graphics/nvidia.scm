;;; NVIDIA proprietary adapter boundary。
;;;
;;; ownership contract：所有 NVIDIA 相关内容【唯一】归属本模块，
;;; 不得散落到 desktop / niri / hosts / kernel-platform / shell：
;;;   1. 匹配所选 %kernel 的 proprietary/open NVIDIA kernel module
;;;   2. NVIDIA userspace stack / nvda
;;;   3. required NVIDIA firmware
;;;   4. DRM KMS policy
;;;   5. nouveau blacklist（proprietary 启用时；本模块专属，禁止写进
;;;      common kernel args / kernel-platform / desktop / VM host）
;;;   6. PRIME render offload / nvidia-prime / prime-run
;;;   7. Mesa -> NVIDIA package transformation（replace-mesa）
;;;   8. hybrid Intel + NVIDIA composition
;;;   9. NVIDIA 特定 power management
;;;  10. Secure Boot module-signing 边界（当前不实现，见下方 TODO）
;;;  11. NVIDIA 特定 kernel arguments
;;;
;;; kernel 唯一 source of truth 仍是 (guixcfg system kernel-platform)
;;; 的 %kernel——NVIDIA adapter 只能 consume 它，不得另选 kernel。
;;; VM / Intel-only host 不调用本 transformation（identity）。
;;;
;;; 实现方式（审计结论，docs/architecture/graphics.md）：全部 NVIDIA
;;; 系统集成委托锁定版 Nonguix 的 nonguix-transformation-nvidia——
;;;   - kernel 字段不被替换（transformation 只改 kernel-arguments/
;;;     packages/services，kernel/initrd/firmware 原样 inherit）；
;;;   - nouveau/nova 黑名单、nvidia_drm.modeset、nvidia-service-type
;;;     （firmware/udev/nvidia-modprobe/linux-loadable-module/nvidia-
;;;     prime/nvidia-powerd）、replace-mesa 全部由 transformation 提供；
;;;   - NVIDIA module 经 linux-module-build-system 的 #:linux 关键字
;;;     自动针对 %kernel 构建（Guix package-for-kernel）。
;;; 本模块只做 machine policy → 明确参数 → transformation 的薄映射。
;;;
;;; machine policy：实机 laptop（RTX 4050 Laptop，Ada）。
;;; NVIDIA 自 R560 起推荐 Turing 及以后 GPU 使用 open kernel
;;; modules，RTX 4050 属 Ada → #:open-source-kernel-module? #t；
;;; dynamic boost 支持自 Ampere 起 → #:dynamic-boost? #t。
;;; 纯 Wayland（greetd/niri，无 Xorg display manager）→
;;; #:configure-xorg? #f。
;;;
;;; TODO（未来，本阶段禁止实现）：若未来自管 kernel 启用
;;; CONFIG_MODULE_SIG_FORCE / lockdown enforcement，NVIDIA
;;; out-of-tree module 需要重新设计第三方 module signing pipeline
;;; （在 Guix build phase 内用 sign-file 签名；签名私钥不得放入
;;; /gnu/store、不得作为普通 derivation input；禁止 activation 期
;;; 修改 store 内 .ko）。当前 kernel（locked 7.2-x86_64.conf）：
;;; CONFIG_MODULE_SIG=n 且无 lockdown——out-of-tree module 无需
;;; 单独签名即可加载（仅 taint）。

(define-module (guixcfg system graphics nvidia)
               #:use-module (nonguix transformations) ; nonguix-transformation-nvidia
               #:use-module (nongnu packages nvidia)  ; nvda-580
               #:use-module (gnu system)              ; operating-system、
                                                      ; operating-system-user-kernel-arguments
               #:export (%nvidia-adapter-enabled?
                         nvidia-kernel-arguments
                         nvidia-system-transformation))

;; 是否启用 NVIDIA（当前 #t：laptop host policy；VM/Intel-only 机器
;; 不调用 nvidia-system-transformation，本模块对其零贡献）。
(define %nvidia-adapter-enabled? #t)

;; NVIDIA 特定 kernel arguments 的 host 级调优 seam（当前空）：
;; transformation 已自动加入 nouveau/nova 黑名单与
;; nvidia_drm.modeset=1；S0ix 等 NVreg 调优参数（如
;; mem_sleep_default=s2idle、nvidia.NVreg_EnableS0ixPowerManagement=1）
;; 未来按需加入，禁止 speculative workaround。
(define nvidia-kernel-arguments '())

(define* (nvidia-system-transformation os
                                       #:key (enabled? %nvidia-adapter-enabled?)
                                             (driver nvda-580)
                                             (open-source-kernel-module? #t)
                                             (kernel-mode-setting? #t)
                                             (configure-xorg? #f)
                                             (dynamic-boost? #t))
         "Thin adapter over Nonguix: map this repo's machine policy to
nonguix-transformation-nvidia.  Returns OS unchanged when DISABLED? is #f
(VM / Intel-only machines: zero NVIDIA contribution).

The kernel is never chosen or replaced here: the transformation inherits
OS's kernel field untouched, so %kernel from (guixcfg system
kernel-platform) remains the single kernel authority; the NVIDIA module is
built against it via linux-module-build-system's #:linux keyword."
         (if enabled?
             ((nonguix-transformation-nvidia
               #:driver driver
               #:open-source-kernel-module? open-source-kernel-module?
               #:kernel-mode-setting? kernel-mode-setting?
               #:configure-xorg? configure-xorg?
               #:dynamic-boost? dynamic-boost?)
              (operating-system
               (inherit os)
               (kernel-arguments
                (append nvidia-kernel-arguments
                        (operating-system-user-kernel-arguments os)))))
             os))
