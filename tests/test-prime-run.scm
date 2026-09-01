;;; Host PRIME Render Offload 测试（docs/architecture/graphics.md
;;; （PRIME offload policy 与 host projection））。
;;;
;;; 覆盖：
;;;   P1 policy 语义 = pinned nonguix nvidia-prime 1.0-5 的 prime-run
;;;      脚本（store 已构建产物逐字节核对过：三变量，无更多）
;;;   P2 driver authority：%nvidia-driver = pinned rolling
;;;      nvda-new-feature selector（不固定 major；transformation
;;;      默认参数引用同一 binding）
;;;   P3 wrapper 脚本（纯函数 prime-run-script）：
;;;      - policy 变量全部出现且由 %prime-offload-environment 单一
;;;        生成（逐一断言 export K=V）；
;;;      - NVIDIA userspace 经 system profile nvidia-smi 符号链
;;;        运行时解析（零 /gnu/store 字面量）；
;;;      - 作用域注入 GLX（LD_LIBRARY_PATH——glvnd 1.7.0 GLX 侧裸名
;;;        dlopen 的唯一生效机制）/ EGL / Vulkan / GBM / VAAPI /
;;;        VDPAU 搜索路径；exec "$@" 语义；
;;;      - 不包含 session-global 风格的 GBM_BACKEND= 固定 vendor 写法
;;;   P4 wrapper 包：name prime-run、trivial-build-system、零 inputs
;;;      （无 build-time driver 耦合；nvda GC 根 = system profile）
;;;   P5 laptop home 获得 wrapper（host capability），默认 %guix-home
;;;      （VM）不获得
;;;   P6 无 session-global NVIDIA offload 变量（laptop home 的
;;;      home-environment-variables-service-type 折叠结果）
;;;   P7 niri laptop variant 的 Intel DRM binding 未被改动（默认
;;;      Intel desktop 的结构事实之一）
;;;   P8 wrapper 版本无关：脚本不含任何 driver-series/版本号字面量
;;;      （rolling driver policy 不变式）
;;;
;;; 纯 Scheme 静态断言，不触发任何 derivation 构建（AGENT.md §1/§2）。

(use-modules ((guixcfg hosts laptop) #:prefix laptop:)
             ((guixcfg hosts vm) #:prefix vm:)
             (guixcfg system graphics nvidia)
             (guixcfg home user)          ; %guix-home（VM/default home）
             (guixcfg utils repository-source) ; repository-file（P7 文件读取）
             (gnu home)                   ; home-environment-packages
             (gnu home services)          ; home-environment-variables-service-type
             (gnu services)               ; fold-services
             (guix build-system trivial)  ; trivial-build-system
             (guix gexp)                  ; local-file-absolute-file-name
             (guix packages)              ; package-name、package-inputs
             (nongnu packages nvidia)     ; nvda-new-feature（rolling selector）
             (ice-9 rdelim)               ; read-string
             (srfi srfi-1)                ; every、find
             (srfi srfi-13)               ; string-contains
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; 私有 binding 经 @@ 取（仓库既有模式，test-nvidia.scm 同款）。
(define prime-run-script
  (@@ (guixcfg system graphics nvidia) prime-run-script))

(test-begin "prime-run")

;; ── P1：policy 与 pinned nonguix upstream 语义一致 ──────────
;; 事实来源：store 已构建的 nvidia-prime-1.0-5（nonguix package 的
;; 源码 = archlinux packaging tag 1.0-5）：
;;   #!/bin/bash
;;   __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only \
;;     __GLX_VENDOR_LIBRARY_NAME=nvidia "$@"
(test-equal "P1: policy matches pinned nonguix nvidia-prime 1.0-5 semantics"
            '(("__NV_PRIME_RENDER_OFFLOAD" . "1")
              ("__VK_LAYER_NV_optimus" . "NVIDIA_only")
              ("__GLX_VENDOR_LIBRARY_NAME" . "nvidia"))
            %prime-offload-environment)

;; ── P2：driver 唯一 authority ───────────────────────────────
(test-assert "P2: %nvidia-driver is the single driver authority (rolling new-feature)"
             (eq? %nvidia-driver nvda-new-feature))

;; ── P3：wrapper 脚本结构 ────────────────────────────────────
(define %script (prime-run-script))

(test-assert "P3: script embeds every policy variable (single source)"
             (every (lambda (entry)
                      (string-contains
                       %script
                       (string-append "export " (car entry)
                                      "=" (cdr entry))))
                    %prime-offload-environment))

(test-assert "P3: script resolves nvda via system profile symlink at runtime"
             (string-contains %script
                              "readlink -f /run/current-system/profile/bin/nvidia-smi"))

(test-assert "P3: script carries no store literals (generation-stable)"
             (not (string-contains %script "/gnu/store")))

(test-assert "P3: GLX vendor library resolution uses scoped LD_LIBRARY_PATH"
             ;; glvnd 1.7.0 libglxmapping.c:290-298 以裸名 dlopen
             ;; "libGLX_nvidia.so.0"——LD_LIBRARY_PATH 是唯一生效机制。
             (string-contains %script
                              "export LD_LIBRARY_PATH=\"$NVDA_LIB"))

(test-assert "P3: EGL vendor json discovery scoped"
             (string-contains %script
                              "export __EGL_VENDOR_LIBRARY_DIRS=\"$NVDA_SHARE/glvnd/egl_vendor.d"))

(test-assert "P3: EGL external platform (NVIDIA wayland) scoped"
             (string-contains %script
                              "export __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=\"$NVDA_SHARE/egl/egl_external_platform.d"))

(test-assert "P3: Vulkan ICD + implicit layer discovery scoped via XDG_DATA_DIRS"
             (string-contains %script
                              "export XDG_DATA_DIRS=\"$NVDA_SHARE"))

(test-assert "P3: GBM/VAAPI/VDPAU scoped per nvda search-path contract"
             (and (string-contains %script
                                   "export GBM_BACKENDS_PATH=\"$NVDA_LIB/gbm")
                  (string-contains %script
                                   "export LIBVA_DRIVERS_PATH=\"$NVDA_LIB/dri")
                  (string-contains %script
                                   "export VDPAU_DRIVER_PATH=\"$NVDA_LIB/vdpau")))

(test-assert "P3: wrapper keeps exec semantics (prime-run cmd args...)"
             (string-contains %script "exec \"$@\""))

(test-assert "P3: no dGPU-only session style (GBM_BACKEND=nvidia-drm) in wrapper"
             (not (string-contains %script "GBM_BACKEND=")))

(test-assert "P8: wrapper is version-independent (no driver-series literals)"
             ;; rolling policy 不变式：prime-run 经 nvidia-smi 符号链
             ;; 运行时解析当前 driver，脚本不得携带任何
             ;; version-specific selector/版本号（580/595/610 等只在
             ;; 测试的 package metadata 断言中出现）。
             (not (or (string-contains %script "nvda-")
                      (string-contains %script "580")
                      (string-contains %script "595")
                      (string-contains %script "610"))))

;; ── P4：wrapper 包结构 ──────────────────────────────────────
(test-assert "P4: wrapper package is named prime-run with trivial build"
             (and (string=? (package-name %prime-run-wrapper) "prime-run")
                  (eq? (package-build-system %prime-run-wrapper)
                       trivial-build-system)))

(test-assert "P4: wrapper has zero inputs (no build-time driver coupling)"
             (null? (package-inputs %prime-run-wrapper)))

;; ── P5：laptop 获得 / VM 不获得 ─────────────────────────────
;; home-environment-packages 可含 (package "output") 形态条目
;; （官方 home service 贡献，如 (list glib "bin")）——归一化取 package。
(define (home-package-entry p)
  (if (package? p) p (car p)))

(test-assert "P5: laptop home provides the prime-run host capability"
             (find (lambda (p)
                     (string=? (package-name (home-package-entry p))
                               "prime-run"))
                   (home-environment-packages laptop:%laptop-guix-home)))

(test-assert "P5: default (VM) home does not provide prime-run"
             (not (find (lambda (p)
                          (string=? (package-name (home-package-entry p))
                                    "prime-run"))
                        (home-environment-packages %guix-home))))

;; ── P6：无 session-global NVIDIA offload 变量 ────────────────
(define %laptop-home-env
  (service-value
   (fold-services (home-environment-services laptop:%laptop-guix-home)
                  #:target-type home-environment-variables-service-type)))

(define %forbidden-global-nvidia-vars
  '("__NV_PRIME_RENDER_OFFLOAD"
    "__VK_LAYER_NV_optimus"
    "__GLX_VENDOR_LIBRARY_NAME"
    "GBM_BACKEND"
    "__EGL_VENDOR_LIBRARY_DIRS"
    "__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS"
    "GBM_BACKENDS_PATH"
    "LIBVA_DRIVERS_PATH"
    "VDPAU_DRIVER_PATH"
    "LD_LIBRARY_PATH"))

(test-assert "P6: no NVIDIA offload environment in session-global home env"
             (not (any (lambda (binding)
                         (member (car binding) %forbidden-global-nvidia-vars))
                       %laptop-home-env)))

;; ── P7：niri laptop variant 的 Intel DRM binding 未被改动 ───
(define %laptop-niri-variant
  (call-with-input-file
   (local-file-absolute-file-name
    (repository-file "modules/guixcfg/apps/niri/variants/laptop.kdl"))
   read-string))

(test-assert "P7: niri laptop variant still binds Intel iGPU and ignores NVIDIA"
             (and (string-contains %laptop-niri-variant
                                   "render-drm-device \"/dev/dri/by-path/pci-0000:00:02.0-render\"")
                  (string-contains %laptop-niri-variant
                                   "ignore-drm-device \"/dev/dri/by-path/pci-0000:01:00.0-card\"")
                  (string-contains %laptop-niri-variant
                                   "ignore-drm-device \"/dev/dri/by-path/pci-0000:01:00.0-render\"")))

(test-end "prime-run")
