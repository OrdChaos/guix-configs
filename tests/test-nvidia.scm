;;; NVIDIA adapter 测试（docs/architecture/graphics.md（NVIDIA adapter
;;; contract）、NVIDIA 专项审计结论）。
;;;
;;; 覆盖：
;;;   N1  disabled = identity：enabled? #f 时 transformation 返回原 OS
;;;       （VM/Intel-only 机器零 NVIDIA 贡献的机制保证）
;;;   N2  kernel authority：transformation 不替换 kernel——%laptop-os
;;;       与 probe OS 的 kernel 仍是 (guixcfg system kernel-platform)
;;;       的 %kernel（唯一权威）；initrd/firmware 字段同样原样保留
;;;   N3  kernel arguments：nouveau/nova 黑名单与 nvidia_drm.modeset=1
;;;       由 transformation 自动加入，且排在原有 user kernel-arguments
;;;       之前；user arguments 原样保留
;;;   N4  open kernel module wiring：%laptop-os 的 nvidia-service-type
;;;       配置为 open 模块（package name "nvidia-module-open"，Ada
;;;       policy）+ nvidia-firmware + powerd #t（dynamic boost）+
;;;       settings #f（无 Xorg display manager）。注意 replace-mesa
;;;       会重建 config 内 package 字段（拷贝），断言按 name 而非 eq?
;;;   N5  replace-mesa：transformation 对 packages 做 mesa → nvda
;;;       grafting（依赖 mesa 的包其 input 的 replacement 是 nvda）
;;;   N6  VM isolation：vm %vm-os 无 nvidia kernel-arguments、无
;;;       nvidia-service-type 实例（packages/firmware 无 nvidia 已由
;;;       test-kernel-platform K8 覆盖）
;;;   N7  laptop %vm-os 实例化（services 字段为合法服务列表）
;;;   N8  driver authority：%nvidia-driver = pinned rolling
;;;       nvda-new-feature selector（不固定 major）
;;;   N9  transformation authority：laptop service driver 版本与
;;;       %nvidia-driver 一致
;;;   N10 userspace/open module/firmware 版本一致 + module 为
;;;       new-feature open 变体（防半迁移；版本从 package metadata
;;;       动态取得）
;;;
;;; 由 tests/run-tests.scm 加载运行（GUIX_CONFIG_FACTS 已设、nonguix
;;; channel 源已加入 load path）；单独运行需先设 GUIX_CONFIG_FACTS
;;; （host 模块实例化 mapped-device 时对 luks-uuid fail-closed）。
;;;
;;; derivation 级证明（NVIDIA module 针对 %kernel/linux-7.2 构建、
;;; VM closure 无 NVIDIA）由 system build + closure 检查完成，不在
;;; 本文件（纯 Scheme 测试不触发构建）。

(use-modules ((guixcfg hosts laptop) #:prefix laptop:)
             ((guixcfg hosts vm) #:prefix vm:)
             (guixcfg system graphics nvidia)
             (guixcfg system kernel-platform)
             (guix packages)              ; package、package-name、package-inputs
             (gnu packages base)          ; hello
             (gnu packages gl)            ; mesa
             (gnu system)                 ; operating-system-*
             (gnu bootloader)             ; bootloader-configuration
             (gnu bootloader grub)        ; grub-bootloader
             (gnu system file-systems)    ; %base-file-systems
             (gnu services)               ; service-kind、service-value
             (nongnu services nvidia)     ; nvidia-service-type、nvidia-configuration-*
             (nongnu packages nvidia)     ; nvda-new-feature、nvidia-module-open-new-feature、
             ; nvidia-firmware-new-feature
             (srfi srfi-1)                ; find、member、list-index
             (srfi srfi-13)               ; string-prefix?
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; probe app：依赖 mesa 的应用，验证 replace-mesa grafting（N5）。
(define nvidia-probe-app
  (package
   (inherit hello)
   (name "nvidia-probe-app")
   (inputs (list mesa))))

;; probe：最小 OS，用于 adapter 语义测试（不依赖 host 组装）。
;; pinned Guix 的 operating-system 要求 bootloader/file-systems 字段。
(define probe-os
  (operating-system
   (host-name "nvidia-probe")
   (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/null"))))
   (file-systems %base-file-systems)
   (kernel %kernel)
   (kernel-arguments '("probe.arg=1"))
   (packages (list mesa nvidia-probe-app))))

(test-begin "nvidia")

;; ── N1：disabled = identity ─────────────────────────────────
(test-eq "N1: transformation is identity when disabled"
         probe-os
         (nvidia-system-transformation probe-os #:enabled? #f))

;; ── N2：kernel authority 保留 ───────────────────────────────
(test-assert "N2: laptop %vm-os still selects %kernel (NVIDIA never replaces the kernel)"
             (eq? (operating-system-kernel laptop:%laptop-os) %kernel))

(test-assert "N2: transformed probe OS still selects %kernel"
             (let ((t (nvidia-system-transformation probe-os)))
               (eq? (operating-system-kernel t) %kernel)))

(test-assert "N2: laptop initrd composition unchanged"
             (eq? (operating-system-initrd laptop:%laptop-os)
                  microcode-ephemeral-initrd))

(test-assert "N2: laptop OS firmware field stays generic linux-firmware (NVIDIA firmware comes via nvidia-service-type)"
             (every (lambda (f)
                      (not (string-contains (package-name f) "nvidia")))
                    (operating-system-firmware laptop:%laptop-os)))

;; ── N3：kernel arguments ────────────────────────────────────
(test-assert "N3: transformation blacklists nouveau and nova, and enables DRM KMS"
             (let ((args (operating-system-user-kernel-arguments
                          (nvidia-system-transformation probe-os))))
               (and (member "modprobe.blacklist=nouveau" args)
                    (member "modprobe.blacklist=nova_core,nova_drm" args)
                    (member "nvidia_drm.modeset=1" args))))

(test-assert "N3: user kernel arguments preserved, nvidia arguments come first"
             (let ((args (operating-system-user-kernel-arguments
                          (nvidia-system-transformation probe-os))))
               (and (member "probe.arg=1" args)
                    (< (list-index (lambda (a) (equal? a "nvidia_drm.modeset=1"))
                                   args)
                       (list-index (lambda (a) (equal? a "probe.arg=1"))
                                   args)))))

(test-assert "N3: laptop %vm-os carries the nvidia kernel arguments"
             (let ((args (operating-system-user-kernel-arguments laptop:%laptop-os)))
               (member "nvidia_drm.modeset=1" args)))

;; ── N4：open kernel module wiring ───────────────────────────
;; (nongnu services nvidia) 只导出 nvidia-configuration/
;; nvidia-service-type，字段 accessor 经 @@ 取私有绑定
;; （仓库既有模式，见 boot/initrd.scm 的 flat-linux-module-directory）。
(define nvidia-configuration-module
  (@@ (nongnu services nvidia) nvidia-configuration-module))
(define nvidia-configuration-driver
  (@@ (nongnu services nvidia) nvidia-configuration-driver))
(define nvidia-configuration-firmware
  (@@ (nongnu services nvidia) nvidia-configuration-firmware))
(define nvidia-configuration-powerd
  (@@ (nongnu services nvidia) nvidia-configuration-powerd))
(define nvidia-configuration-settings
  (@@ (nongnu services nvidia) nvidia-configuration-settings))

(define laptop-nvidia-service
  (find (lambda (s)
          (eq? (service-kind s) nvidia-service-type))
        (operating-system-user-services laptop:%laptop-os)))

(test-assert "N4: laptop %vm-os includes nvidia-service-type"
             laptop-nvidia-service)

(test-assert "N4: open kernel module selected (Ada policy)"
             ;; replace-mesa 的 with-transformation 会递归重建
             ;; nvidia-configuration 内的 package 字段（package-
             ;; input-rewriting 的拷贝），因此不能 eq? 原绑定——
             ;; 按 package name 断言：rolling %nvidia-driver
             ;; （nvda-new-feature）经 transformation 推导的 open
             ;; 变体名从 pinned binding 动态取得（nonguix 对
             ;; new-feature/beta 分支使用带分支后缀的模块名，
             ;; 与 production 分支的 "nvidia-module-open" 不同）。
             (and laptop-nvidia-service
                  (string=? (package-name
                             (nvidia-configuration-module
                              (service-value laptop-nvidia-service)))
                            (package-name
                             nvidia-module-open-new-feature))))

(test-assert "N4: driver is nvda and firmware is the branch firmware"
             (and laptop-nvidia-service
                  (string=? (package-name
                             (nvidia-configuration-driver
                              (service-value laptop-nvidia-service)))
                            "nvda")
                  (string=? (package-name
                             (nvidia-configuration-firmware
                              (service-value laptop-nvidia-service)))
                            (package-name
                             nvidia-firmware-new-feature))))

(test-assert "N4: dynamic boost enabled (powerd #t) and no Xorg settings"
             (and laptop-nvidia-service
                  (eq? (nvidia-configuration-powerd
                        (service-value laptop-nvidia-service))
                       #t)
                  (not (nvidia-configuration-settings
                        (service-value laptop-nvidia-service)))))

;; ── N5：replace-mesa grafting ───────────────────────────────
(test-assert "N5: mesa dependency of a package is grafted to nvda"
             ;; package-input-grafting 的 graft-package 保留原包名、
             ;; 通过 replacement 指向 nvda（mesa/nvda 名字长度相同，
             ;; replacement 直接继承 rolling %nvidia-driver（nvda-new-feature），
             ;; package-name = "nvda"）。
             (let* ((t (nvidia-system-transformation probe-os))
                    (app (find (lambda (p)
                                 (string=? (package-name p)
                                           "nvidia-probe-app"))
                               (operating-system-packages t)))
                    (inputs (and app (package-inputs app)))
                    ;; package-inputs 元素是 (label package) list
                    (input (and (pair? inputs)
                                (let ((f (car inputs)))
                                  (if (package? f) f (cadr f)))))
                    (repl (and input (package-replacement input))))
               (and input repl
                    (string=? (package-name repl) "nvda"))))

;; ── N6：VM isolation ────────────────────────────────────────
(test-assert "N6: vm %vm-os has no nvidia kernel arguments"
             (every (lambda (a)
                      (and (string? a)
                           (not (string-contains a "nvidia"))))
                    (operating-system-user-kernel-arguments vm:%vm-os)))

(test-assert "N6: vm %vm-os has no nvidia-service-type instance"
             (not (find (lambda (s)
                          (eq? (service-kind s) nvidia-service-type))
                        (operating-system-user-services vm:%vm-os))))

;; ── N7：laptop %vm-os 实例化 ───────────────────────────────────
(test-assert "N7: laptop %vm-os instantiates (valid services field)"
             (list? (operating-system-services laptop:%laptop-os)))

;; ── N8-N10：driver policy（rolling new-feature）────────────
;; 不变式（docs/architecture/graphics.md（NVIDIA driver policy））：
;;   N8  %nvidia-driver 是唯一 authority，绑定 pinned rolling
;;       selector（nvda-new-feature），不固定任何 NVIDIA major；
;;   N9  laptop 的 nvidia-service-type 配置由 transformation 从
;;       %nvidia-driver 推导（driver 版本与 authority 一致）；
;;   N10 userspace / open kernel module / firmware 三者版本一致，
;;       且 module 是 new-feature branch 的 open 变体——即
;;       transformation 的配套 mapping 生效，不存在
;;       “userspace=new-feature + module=580” 半迁移状态。
;;       版本号只从 package metadata 动态取得，不做字符串断言。
;;       版本一致性断言同时覆盖未来 lock 升级：任何 branch 内漂移
;;       （如 610 → 615）在三者同步的情况下保持通过。
(test-assert "N8: %nvidia-driver is the rolling new-feature selector"
             (eq? %nvidia-driver nvda-new-feature))

(test-assert "N9: laptop service driver derives from %nvidia-driver (version match)"
             (and laptop-nvidia-service
                  (string=? (package-version
                             (nvidia-configuration-driver
                              (service-value laptop-nvidia-service)))
                            (package-version %nvidia-driver))))

(test-assert "N10: userspace / open module / firmware are version-consistent"
             ;; nvda 的 version 字段被 nonguix 有意截断为
             ;; mesa-for-nvda 版本长度（"610.57"），因此 userspace 的
             ;; 完整版本以 nvda 的源 driver（nvidia-driver-new-feature）
             ;; 为准；module 与 firmware 的 version 直接取自同一
             ;; pinned nvidia-source-new-feature（610.57.04）——
             ;; 三者同源即同版本，transformation 的配套 mapping 生效。
             (and laptop-nvidia-service
                  (let ((driver (nvidia-configuration-driver
                                 (service-value laptop-nvidia-service)))
                        (module (nvidia-configuration-module
                                 (service-value laptop-nvidia-service)))
                        (firmware (nvidia-configuration-firmware
                                   (service-value laptop-nvidia-service))))
                    (and (string=? (package-name module)
                                   (package-name
                                    nvidia-module-open-new-feature))
                         (string=? (package-version nvidia-driver-new-feature)
                                   (package-version module))
                         (string=? (package-version nvidia-driver-new-feature)
                                   (package-version firmware))
                         (string-prefix? (package-version driver)
                                         (package-version
                                          nvidia-driver-new-feature))))))

(test-assert "N10: open module is the new-feature branch realization (no half-migration)"
             (and laptop-nvidia-service
                  (string=? (package-version
                             (nvidia-configuration-module
                              (service-value laptop-nvidia-service)))
                            (package-version nvidia-module-open-new-feature))))

(test-end "nvidia")
