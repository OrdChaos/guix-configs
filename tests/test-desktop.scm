;;; M2 Wayland desktop 单元测试（D1-D7 可单元化部分 + NV1-NV8）。
;;;
;;; 覆盖：
;;;   D1 greetd 配置生成（tty1 terminal）
;;;   D2 greetd gated by interactive-session-ready（shepherd requirement）
;;;   D3 tty2 mingetty fallback 保留（且同样 gated）
;;;   D4 无 autologin（initial-session-user #f）+ 空密码禁用
;;;   D5 elogind 仍是唯一 session authority（服务存在）
;;;   D6/D7 /run/user 生命周期属 runtime（VM acceptance，见报告）
;;;   NV1 NVIDIA adapter 默认 disabled/identity
;;;   NV2 VM OS 无 proprietary NVIDIA 包
;;;   NV3 VM kernel args 无 nouveau blacklist
;;;   NV4 common desktop 模块不引用 NVIDIA/vendor 符号（无 layer leak）
;;;   NV5 NVIDIA adapter 拥有并记录未来 ownership
;;;   NV6 kernel 仍由 kernel-platform 拥有
;;;   NV7 未来 package-transform 默认 identity
;;;   NV8 无全局 PRIME/DRM 环境变量（niri config + desktop 源码）
;;;
;;; 不构建任何 NVIDIA 内容、不访问公网（niri validate 等属 VM
;;; runtime acceptance）。

(use-modules (guixcfg hosts vm)
             (guixcfg system desktop)
             (guixcfg system graphics nvidia)
             (guixcfg system kernel-platform)
             (gnu services)
             (gnu services base)   ; greetd-service-type、mingetty-service-type
             (gnu services desktop) ; elogind-service-type
             (gnu services shepherd) ; shepherd-root-service-type
             (gnu system)          ; operating-system-*
             (guix packages)       ; package-name
             (nongnu packages linux) ; linux（nonguix）
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (os-service service-type)
  "从 %os 的 services 里按 SERVICE-TYPE 折叠出配置。"
  (fold-services (operating-system-services %os)
                 #:target-type service-type))

(define (all-shepherd-services)
  "%os 的 shepherd root 服务列表。"
  (service-value
   (os-service shepherd-root-service-type)))

;; greetd 记录访问器未从 (gnu services base) 导出，经模块内绑定访问。
(define greetd-terminals (@ (gnu services base) greetd-terminals))
(define greetd-allow-empty-passwords?
  (@ (gnu services base) greetd-allow-empty-passwords?))
(define greetd-terminal-vt
  (@ (gnu services base) greetd-terminal-vt))
(define greetd-terminal-configuration-initial-session-user
  (@ (gnu services base) greetd-initial-session-user))

(define (os-services-of-type type)
  "扫描 %os 的 services 列表（不 fold——mingetty 等多实例类型）。"
  (filter (lambda (svc) (eq? (service-kind svc) type))
          (operating-system-services %os)))

(test-begin "desktop")

;; ── D1：greetd 配置生成 ────────────────────────────────────
(test-assert "D1: greetd service present with a tty1 terminal"
             (let ((cfg (service-value (os-service greetd-service-type))))
               (and (pair? (greetd-terminals cfg))
                    (any (lambda (tc)
                           (string=? "1" (greetd-terminal-vt tc)))
                         (greetd-terminals cfg)))))

;; ── D2：greetd gated by interactive-session-ready ──────────
(test-assert "D2: greetd tty1 requires interactive-session-ready"
             (let* ((cfg (service-value (os-service greetd-service-type)))
                    (tc (find (lambda (tc)
                                (string=? "1" (greetd-terminal-vt tc)))
                              (greetd-terminals cfg))))
               (member 'interactive-session-ready
                       ((@ (gnu services base) greetd-extra-shepherd-requirement)
                        tc))))

;; ── D3：tty1 归 greetd，mingetty fallback 在 tty2+ 且 gated ──
(test-assert "D3: no mingetty on tty1 (greetd owns it)"
             (not (any (lambda (svc)
                         (string=? "tty1"
                                   (mingetty-configuration-tty
                                    (service-value svc))))
                       (os-services-of-type mingetty-service-type))))

(test-assert "D3: mingetty fallback present on tty2"
             (any (lambda (svc)
                    (string=? "tty2"
                              (mingetty-configuration-tty
                               (service-value svc))))
                  (os-services-of-type mingetty-service-type)))

(test-assert "D3: fallback mingetty gated by interactive-session-ready"
             (any (lambda (svc)
                    (member 'interactive-session-ready
                            (mingetty-configuration-shepherd-requirement
                             (service-value svc))))
                  (os-services-of-type mingetty-service-type)))

;; ── D4：无 autologin、空密码禁用 ───────────────────────────
(test-assert "D4: no autologin (initial-session-user unset)"
             (let ((cfg (service-value (os-service greetd-service-type))))
               (every (lambda (tc)
                        (not (greetd-terminal-configuration-initial-session-user
                              tc)))
                      (greetd-terminals cfg))))

(test-assert "D4: empty passwords disabled"
             (not (greetd-allow-empty-passwords?
                   (service-value (os-service greetd-service-type)))))

;; ── D5：elogind 仍是 session authority ─────────────────────
(test-assert "D5: elogind service present in %os"
             (let ((cfg (os-service elogind-service-type)))
               (and cfg #t)))

;; ── NV1：NVIDIA adapter 默认 disabled/identity ─────────────
(test-assert "NV1: NVIDIA adapter disabled by default"
             (not %nvidia-adapter-enabled?))

(test-assert "NV1: adapter contributions are empty"
             (and (null? nvidia-kernel-arguments)
                  (null? nvidia-system-packages)
                  (null? nvidia-system-services)
                  (null? nvidia-user-packages)))

;; ── NV2：VM OS 无 proprietary NVIDIA 包 ────────────────────
(test-assert "NV2: %os packages contain no nvidia stack"
             (every (lambda (p)
                      (not (string-contains (package-name p) "nvidia")))
                    (operating-system-packages %os)))

;; ── NV3：VM kernel args 无 nouveau blacklist ───────────────
(test-assert "NV3: VM configuration adds no nouveau blacklist"
             ;; kernel-arguments 是 gexp（lower 前不可直接扫描）；从声明
             ;; 层断言：host/desktop/adapter 都没有引入 nouveau（Guix
             ;; 默认 args 仅 modprobe.blacklist=usbmouse,usbkbd + quiet）。
             (let ((s (call-with-input-file "modules/guixcfg/hosts/vm.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "nouveau"))))

;; ── NV4：desktop/niri 模块无 vendor layer leak ─────────────
(define %vendor-words
  ;; 注意："xe" 作为独立 token 才相关（i915/xe），不单独列出——
  ;; 会误匹配 execl 等子串；"i915" 已覆盖 Intel driver 路径。
  '("nvidia" "nouveau" "nvda" "virtio_gpu" "i915" "renderD"
    "/dev/dri" "card0" "card1"))

(define (text-contains-any? text words)
  (any (lambda (w) (string-contains text w)) words))

(test-assert "NV4: desktop.scm has no vendor-specific references"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s %vendor-words))))

(test-assert "NV4: niri config has no DRM node / output name"
             (let ((s (call-with-input-file "files/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s
                                        (append %vendor-words
                                                '("Virtual-1" "eDP-1"
                                                  "DP-1" "HDMI-A-1"))))))

;; ── NV5：NVIDIA adapter 记录未来 ownership ─────────────────
(test-assert "NV5: nvidia adapter module documents its ownership"
             (let ((s (call-with-input-file
                       "modules/guixcfg/system/graphics/nvidia.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "nouveau blacklist")
                    (string-contains s "PRIME")
                    (string-contains s "Secure Boot module-signing")
                    (string-contains s "kernel-platform"))))

;; ── NV6：kernel 仍由 kernel-platform 拥有 ──────────────────
(test-assert "NV6: %os kernel is still %kernel (kernel-platform owns it)"
             (eq? (operating-system-kernel %os) %kernel))

;; ── NV7：package-transform 默认 identity ───────────────────
(test-assert "NV7: nvidia package transform defaults to identity"
             (eq? nvidia-package-transform identity))

;; ── NV8：无全局 PRIME/DRM 环境变量 ─────────────────────────
(test-assert "NV8: niri config has no global PRIME/DRM env vars"
             (let ((s (call-with-input-file "files/niri/config.kdl"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s
                                        '("PRIME" "WLR_DRM_DEVICES"
                                          "GBM_BACKEND" "WLR_RENDERER"
                                          "WLR_BACKENDS")))))

(test-assert "NV8: desktop.scm sets no global vendor env vars"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (text-contains-any? s
                                        '("PRIME" "WLR_DRM_DEVICES"
                                          "GBM_BACKEND" "__GLX_VENDOR")))))

(test-end "desktop")
