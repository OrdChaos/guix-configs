;;; NVIDIA proprietary adapter boundary（M2：skeleton，默认 disabled/
;;; identity——不改变任何系统 closure / graphics behavior）。
;;;
;;; ownership contract：未来所有 NVIDIA 相关内容【唯一】归属本模块，
;;; 不得散落到 desktop / niri / hosts / kernel-platform / shell：
;;;   1. 匹配所选 %kernel 的 proprietary NVIDIA kernel module
;;;   2. NVIDIA userspace stack / nvda
;;;   3. required NVIDIA firmware
;;;   4. DRM KMS policy
;;;   5. nouveau blacklist（proprietary 启用时；本模块专属，禁止写进
;;;      common kernel args / kernel-platform / desktop / VM host）
;;;   6. PRIME render offload / nvidia-prime / prime-run
;;;   7. Mesa -> NVIDIA package transformation（replace-mesa，如确需）
;;;   8. hybrid Intel + NVIDIA composition
;;;   9. NVIDIA 特定 power management
;;;  10. Secure Boot module-signing integration（NVIDIA/kernel 边界）
;;;  11. NVIDIA 特定 kernel arguments
;;;
;;; kernel 唯一 source of truth 仍是 (guixcfg system kernel-platform)
;;; 的 %kernel——NVIDIA adapter 只能 consume 它，不得另选 kernel。
;;; VM / 普通 Intel / Intel-only host：全部走默认（本模块 identity）。
;;;
;;; 当前（M2）：%nvidia-adapter-enabled? = #f，所有贡献为空——
;;; 明确建立 seam 但不启用任何 NVIDIA 内容（docs/architecture/
;;; graphics.md（NVIDIA adapter contract））。

(define-module (guixcfg system graphics nvidia)
               #:export (%nvidia-adapter-enabled?
                         nvidia-kernel-arguments
                         nvidia-system-packages
                         nvidia-system-services
                         nvidia-user-packages
                         nvidia-package-transform))

;; 是否启用 proprietary NVIDIA（M2 固定 #f；未来由具体 host policy
;; 决定，且只在真实 NVIDIA 硬件存在时）。
(define %nvidia-adapter-enabled? #f)

;; 未来 enabled 时的贡献点（当前全部 identity/空——VM/Intel 不受影响）：
;; kernel cmdline 附加（如 nouveau blacklist 属于本模块，仅 enabled 时）
(define nvidia-kernel-arguments '())
;; 系统级包/服务（kernel module、KMS 等）
(define nvidia-system-packages '())
(define nvidia-system-services '())
;; 用户级包（nvda、nvidia-prime/prime-run 等 application capability）
(define nvidia-user-packages '())
;; Mesa -> NVIDIA 的 package transformation（默认 identity；
;; 仅在真实需要时由本模块提供，禁止全局 replace-mesa）
(define nvidia-package-transform identity)
