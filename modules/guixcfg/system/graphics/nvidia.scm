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
;;;   6. PRIME render offload policy（单一 authority：%prime-offload-
;;;      environment，与 pinned nonguix nvidia-prime 1.0-5 upstream
;;;      语义一致）+ host projection（%prime-run-wrapper，作用域内
;;;      注入 NVIDIA userspace；未来 Flatpak projection 复用同一
;;;      policy 数据，只投影环境语义、不投影 Guix 路径）
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
;;; driver 唯一 authority：%nvidia-driver。
;;;
;;; channel policy（rolling）：%nvidia-driver 选择 pinned Nonguix 的
;;; New Feature Branch selector（nvda-new-feature）——【不】固定任何
;;; NVIDIA major。可复现性边界 = channels.lock.scm 精确 pin 住
;;; nonguix revision，因此：
;;;   selector stability（源代码里的 nvda-new-feature 不变）
;;;   ≠
;;;   realization version stability（610.x → 615.x → 620.x 随 lock
;;;   漂移，属预期行为）
;;; userspace / open kernel module / firmware / modprobe / settings /
;;; service 全部由 pinned Nonguix 的 nonguix-transformation-nvidia
;;; 根据同一个 %nvidia-driver 自动推导（transformations.scm 的
;;; %module/%firmware/%modprobe/%settings mapping）——仓库不复制任何
;;; driver mapping table；升级时它们作为一个原子兼容性单元验证
;;; （tests/test-nvidia.scm N8-N10、tests/test-prime-run.scm）。
;;; 注意：nonguix README 明确 nvda-new-feature 为 "not
;;; production-ready"（rolling branch 的固有属性，本仓库 policy 已
;;; 接受）。未来 Steam/gamescope/Flatpak 等 consumers 同源引用
;;; %nvidia-driver，禁止散落任何 version-specific 字面量（580/595/
;;; 610 等只允许出现在测试的 package metadata 断言与验证输出中）。
;;;
;;; PRIME offload policy 与 host projection：
;;;   %prime-offload-environment —— 中性 policy 数据（变量语义与
;;;     pinned nonguix nvidia-prime 1.0-5 的 prime-run 脚本逐字节
;;;     一致：__NV_PRIME_RENDER_OFFLOAD / __VK_LAYER_NV_optimus /
;;;     __GLX_VENDOR_LIBRARY_NAME）。host projection 与未来的
;;;     Flatpak projection 都消费它；任何 NVIDIA offload 变量都
;;;     【不得】出现在 session-global 环境（graphics.md 契约）。
;;;   %prime-run-wrapper —— host projection：Home profile（laptop
;;;     only，hosts/laptop.scm 组装）作用域 wrapper。根因背景：
;;;     pinned Guix mesa 是经典构建（-Dglx=dri，无 glvnd dispatch），
;;;     Home 应用闭包只有 Intel；offload 需要把 libGL/libEGL 入口切
;;;     到 glvnd 并把 NVIDIA vendor 库/ICD 路径作用域注入（细节见
;;;     prime-run-script 注释）。wrapper 零 build-time driver input、
;;;     运行时经 system profile 的 nvidia-smi 符号链解析 nvda
;;;     prefix——跨 generation 稳定，不嵌入 store 字面量。
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
               #:use-module (nongnu packages nvidia)  ; nvda-new-feature（rolling selector）
               #:use-module (gnu system)              ; operating-system、
               ; operating-system-user-kernel-arguments
               #:use-module (guix build-system trivial) ; trivial-build-system（%prime-run-wrapper）
               #:use-module (guix gexp)               ; plain-file
               #:use-module ((guix licenses) #:prefix license:) ; license:gpl3+
               #:use-module (guix packages)           ; package
               #:use-module (srfi srfi-1)             ; every
               #:use-module (srfi srfi-13)            ; string-every
               #:export (%nvidia-adapter-enabled?
                         %nvidia-driver
                         nvidia-kernel-arguments
                         %prime-offload-environment
                         %prime-run-wrapper
                         nvidia-system-transformation))

;; 是否启用 NVIDIA（当前 #t：laptop host policy；VM/Intel-only 机器
;; 不调用 nvidia-system-transformation，本模块对其零贡献）。
(define %nvidia-adapter-enabled? #t)

;; NVIDIA userspace driver 的唯一 authority（package binding）：
;; rolling New Feature Branch selector——具体 realization（610.x →
;; 615.x → …）由 channels.lock.scm pin 住的 nonguix revision 决定，
;; 禁止在仓库任何 consumer 中写死 major。本模块的 transformation
;; 与 host prime-run projection 都从这里取；配套（open module /
;; firmware / modprobe / settings）由 pinned Nonguix transformation
;; 按同一 binding 自动推导（见文件头）。未来 Steam（steam-for
;; %nvidia-driver）等 consumers 同源引用。
(define %nvidia-driver nvda-new-feature)

;; NVIDIA 特定 kernel arguments 的 host 级调优 seam（当前空）：
;; transformation 已自动加入 nouveau/nova 黑名单与
;; nvidia_drm.modeset=1；S0ix 等 NVreg 调优参数（如
;; mem_sleep_default=s2idle、nvidia.NVreg_EnableS0ixPowerManagement=1）
;; 未来按需加入，禁止 speculative workaround。
(define nvidia-kernel-arguments '())

;;; ────────────────────────────────────────────────────────────
;;; PRIME Render Offload policy（中性数据，单一 authority）
;;;
;;; 语义与 pinned nonguix nvidia-prime 1.0-5 的 prime-run 脚本
;;; （gitlab.archlinux.org archlinux/packaging/packages/nvidia-prime
;;;  tag 1.0-5，store 已构建产物逐字节核对）一致：
;;;   __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only \
;;;   __GLX_VENDOR_LIBRARY_NAME=nvidia "$@"
;;; host projection（%prime-run-wrapper）消费它生成作用域脚本；未来
;;; Flatpak projection 消费同一数据渲染 --env 参数（只投影环境
;;; 语义，不投影 Guix store 路径 / profile / 动态链接器）。
(define %prime-offload-environment
  '(("__NV_PRIME_RENDER_OFFLOAD" . "1")
    ("__VK_LAYER_NV_optimus" . "NVIDIA_only")
    ("__GLX_VENDOR_LIBRARY_NAME" . "nvidia")))

(define (shell-variable-name? s)
  "S 是合法 POSIX shell 变量名（策略数据防注入；允许下划线开头，
如 __NV_PRIME_RENDER_OFFLOAD）。"
  (and (string? s) (> (string-length s) 0)
       (or (char-alphabetic? (string-ref s 0))
           (char=? (string-ref s 0) #\_))
       (string-every (lambda (c)
                       (or (char-alphabetic? c)
                           (char-numeric? c)
                           (char=? c #\_)))
                     (substring s 1))))

(define (safe-shell-value? s)
  "S 不含 shell 元字符（策略值由仓库常量控制；fail-fast 防止未来把
不安全字符串注入生成的 wrapper 脚本）。"
  (and (string? s)
       (string-every (lambda (c)
                       (not (memv c '(#\" #\' #\$ #\` #\newline #\space))))
                     s)))

(define (valid-prime-offload-environment-entry? entry)
  "(NAME . VALUE) 对且两者安全（见上）。"
  (and (pair? entry)
       (shell-variable-name? (car entry))
       (safe-shell-value? (cdr entry))))

(unless (every valid-prime-offload-environment-entry?
               %prime-offload-environment)
  (error "invalid PRIME offload environment entry"
         %prime-offload-environment))

(define (prime-run-script)
  "生成 host prime-run wrapper 脚本文本（纯函数，供测试静态断言）。
职责边界：policy 变量来自 %prime-offload-environment（中性 seam）；
其余导出是本模块 host projection 的 Guix 特有路径注入，只在本命令
作用域生效。

NVIDIA userspace 位置：当前 system profile 的 nvda（nvidia-service-
type profile 注入）——经 /run/current-system/profile/bin/nvidia-smi
符号链解析出 nvda 的 store prefix。零 store 字面量、跨 system
generation 稳定；nvda 缺失时 fail-loud（绝不静默退回 Intel）。

根因与机制（pinned source 核对）：
  - pinned Guix mesa 以 -Dglx=dri 构建（经典 libGL/libEGL，无
    glvnd dispatch）——__NV_PRIME_RENDER_OFFLOAD /
    __GLX_VENDOR_LIBRARY_NAME 对经典 mesa 无效，且 Home 闭包只有
    Intel。LD_LIBRARY_PATH 把 libGL/libEGL 入口在作用域内切到
    nvda 的 glvnd dispatch，vendor 变量才有消费者；
  - glvnd 1.7.0 GLX 侧以【裸名】dlopen \"libGLX_nvidia.so.0\"
    （libglxmapping.c:290-298），不读 __GLX_VENDOR_LIBRARY_DIRS——
    LD_LIBRARY_PATH 是 GLX vendor 库解析的唯一生效机制；
  - EGL 侧读 __EGL_VENDOR_LIBRARY_DIRS 扫描 *.json（libeglvendor.c
    :59-64；library_path 相对 json 目录解析）；
  - Vulkan loader 经 XDG_DATA_DIRS 发现 nvda 的 icd.d 与 implicit
    layer（__VK_LAYER_NV_optimus）。
其余（GBM/EGL external platform/VAAPI/VDPAU）按 nvda 自身
native-search-paths 契约作用域投影。"
  (string-append
   "#!/bin/sh\n"
   "# Host PRIME render offload wrapper — (guixcfg system graphics nvidia).\n"
   "# Policy env from %prime-offload-environment (single authority);\n"
   "# NVIDIA userspace resolved from the current system profile's nvda\n"
   "# via the nvidia-smi symlink (no store literals, generation-stable).\n"
   "# All variables are scoped to the launched command only.\n"
   "NVDA_SMI=$(readlink -f /run/current-system/profile/bin/nvidia-smi) || {\n"
   "  echo \"prime-run: NVIDIA driver not found in system profile\" >&2\n"
   "  exit 1\n"
   "}\n"
   "NVDA_PREFIX=$(dirname \"$(dirname \"$NVDA_SMI\")\")\n"
   "NVDA_LIB=\"$NVDA_PREFIX/lib\"\n"
   "NVDA_SHARE=\"$NVDA_PREFIX/share\"\n"
   "\n"
   ;; PRIME policy（与 pinned nonguix nvidia-prime 1.0-5 语义一致）。
   (string-join (map (lambda (entry)
                       (string-append "export " (car entry) "=" (cdr entry)))
                     %prime-offload-environment)
                "\n")
   "\n"
   ;; Guix host projection：nvda（glvnd + mesa-for-nvda + NVIDIA
   ;; userspace）作用域注入。
   "export LD_LIBRARY_PATH=\"$NVDA_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\n"
   "export XDG_DATA_DIRS=\"$NVDA_SHARE${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}\"\n"
   "export __EGL_VENDOR_LIBRARY_DIRS=\"$NVDA_SHARE/glvnd/egl_vendor.d${__EGL_VENDOR_LIBRARY_DIRS:+:$__EGL_VENDOR_LIBRARY_DIRS}\"\n"
   "export __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=\"$NVDA_SHARE/egl/egl_external_platform.d${__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS:+:$__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS}\"\n"
   "export GBM_BACKENDS_PATH=\"$NVDA_LIB/gbm${GBM_BACKENDS_PATH:+:$GBM_BACKENDS_PATH}\"\n"
   "export LIBVA_DRIVERS_PATH=\"$NVDA_LIB/dri${LIBVA_DRIVERS_PATH:+:$LIBVA_DRIVERS_PATH}\"\n"
   "export VDPAU_DRIVER_PATH=\"$NVDA_LIB/vdpau${VDPAU_DRIVER_PATH:+:$VDPAU_DRIVER_PATH}\"\n"
   "\n"
   "exec \"$@\"\n"))

;; host projection 包：Home profile（laptop only，hosts/laptop.scm
;; 组装）提供 bin/prime-run，PATH 上遮蔽 system profile 里
;; nvidia-service-type 注入的 upstream nvidia-prime prime-run。
;; 零 inputs：无 build-time driver 耦合（运行时解析 system profile），
;; derivation 平凡（单元测试可静态断言；nvda 的 GC 根 = system
;; profile，wrapper 无需引用）。
(define %prime-run-wrapper
  (package
   (name "prime-run")
   (version "1.0")
   (source #f)
   (build-system trivial-build-system)
   (arguments
    (list
     #:modules '((guix build utils))
     #:builder
     #~(begin
        (use-modules (guix build utils))
        (mkdir-p (string-append #$output "/bin"))
        (copy-file #$(plain-file "prime-run" (prime-run-script))
                   (string-append #$output "/bin/prime-run"))
        (chmod (string-append #$output "/bin/prime-run") #o555))))
   (home-page
    "https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-prime")
   (synopsis "Scoped NVIDIA PRIME render offload launcher")
   (description
    "Host capability wrapper around the NVIDIA PRIME render offload
environment (semantics of the upstream nvidia-prime package).  It
resolves the @code{nvda} userspace from the current system profile and
runs COMMAND with NVIDIA-only GL/EGL/Vulkan vendor selection, scoped
to that command.  The default Intel iGPU desktop is unaffected.")
   (license license:gpl3+)))

(define* (nvidia-system-transformation os
                                       #:key (enabled? %nvidia-adapter-enabled?)
                                       (driver %nvidia-driver)
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
