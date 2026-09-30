;;; Laptop power management：TLP + tlp-pd（docs/architecture/power.md）。
;;;
;;; ownership contract：所有 AC/BAT 功耗策略【唯一】归属本模块，由
;;; laptop host 消费；VM / 非笔记本 host 不引用本模块（零 power
;;; closure），与 (guixcfg system graphics nvidia) 的 gating 同构。
;;;
;;; 实现方式（官方机制，AGENTS §6-7）：
;;;   - TLP 是 pinned Guix 的官方 tlp-service-type；本仓库只提供
;;;     machine policy（tlp-configuration 的显式字段）。
;;;   - tlp-pd（TLP 1.9 自带的 profiles daemon）由 virelith channel
;;;     的 tlp-with-pd 包提供（官方 tlp 包不安装它）。tlp-pd 实现
;;;     org.freedesktop.UPower.PowerProfiles（+ legacy
;;;     net.hadess.PowerProfiles）D-Bus 接口，桌面 shell 的
;;;     power-profile 控件因此可用，而实际控制仍是 TLP 的三个 profile
;;;     （_ON_AC / _ON_BAT / _ON_SAV，含离电自动切换）。
;;;
;;; single owner（强不变式）：不能同时运行 power-profiles-daemon——
;;; 它与 tlp-pd 争用同一 bus name，且 TLP 1.6+ 检测到 PPD 时会主动
;;; 让出 4 项重叠设置。故本模块不引入 PPD，测试固定该不变量。
;;;
;;; TLP 配置字段：只覆盖需要显式化的机器策略，其余交给 TLP 自身
;;; 优化过的 defaults.conf（records 的 maybe-* 字段未设置时不写
;;; /etc/tlp.conf）。注意 disks-devices：Guix tlp-configuration 的
;;; record 默认是 ("sda")，会覆盖 TLP default 的 "nvme0n1 sda"——本
;;; 机从 NVMe 启动，必须显式保留 nvme0n1。

(define-module (guixcfg system power)
               #:use-module (gnu services)            ; service、simple-service
               #:use-module (gnu services dbus)       ; dbus-root-service-type、polkit-service-type
               #:use-module (gnu services pm)         ; tlp-service-type、tlp-configuration
               #:use-module (gnu services shepherd)   ; shepherd-service
               #:use-module (gnu packages glib)        ; glib（gdbus：TLP -> tlp-pd 回调）
               #:use-module (guix gexp)               ; file-append
               #:use-module (virelith packages tlp)   ; tlp-with-pd
               #:export (%laptop-tlp-configuration
                         %laptop-power-services))

;; laptop TLP 机器策略。字段语义以 pinned Guix (gnu services pm) 为准；
;; 变更这里即改变整机 AC/BAT 功耗行为。
(define %laptop-tlp-configuration
  (tlp-configuration
   (tlp tlp-with-pd)
   ;; intel_pstate EPP：插电平衡性能，离电偏向省电（与 TLP 默认一致，
   ;; 显式化以固定策略）。
   (cpu-energy-perf-policy-on-ac "balance_performance")
   (cpu-energy-perf-policy-on-bat "balance_power")
   ;; 睿频是 CPU 功耗的主要来源；离电关闭。
   (cpu-boost-on-ac? #t)
   (cpu-boost-on-bat? #f)
   ;; 本机启动盘是 NVMe（Guix record 默认只有 "sda"）。
   (disks-devices '("nvme0n1" "sda"))))

;; tlp-pd：常驻 root 服务，claim PPD 的 system bus name。必须在
;; dbus-system 之后启动（否则 claim name 失败）。wrapper（virelith
;; 包）已注入 python/GI 与自身 sbin；TLP 在 profile 应用后必须用 gdbus
;; 调 SyncProfile 更新 PPD D-Bus 状态，所以显式提供 glib/bin。系统 profile
;; 本身不含 gdbus，缺少它会导致硬件 profile 已变、Noctalia 却显示旧值。
(define %tlp-pd-shepherd-service
  (shepherd-service
   (documentation "TLP profiles daemon (org.freedesktop.UPower.PowerProfiles API).")
   (provision '(tlp-pd))
   (requirement '(dbus-system))
   (start #~(make-forkexec-constructor
             (list #$(file-append tlp-with-pd "/sbin/tlp-pd"))
             #:environment-variables
             (list (string-append "PATH="
                                  #$(file-append glib "/bin")
                                  ":/run/current-system/profile/bin"))))
   (stop #~(make-kill-destructor))))

;; laptop power services（host 经 additional-system-services 消费）：
;;   - TLP 服务（含 udev AC/BAT 规则与 activation 写 /etc/tlp.conf）；
;;   - tlp-pd shepherd 服务；
;;   - tlp-with-pd 的 D-Bus system policy（dbus-root-service-type 收集
;;     share/dbus-1/system.d）；
;;   - tlp-with-pd 的 polkit action（polkit-service-type 收集
;;     share/polkit-1/actions）。
(define %laptop-power-services
  (list (service tlp-service-type %laptop-tlp-configuration)
        (simple-service 'tlp-pd shepherd-root-service-type
                        (list %tlp-pd-shepherd-service))
        (simple-service 'tlp-pd-dbus-policy dbus-root-service-type
                        (list tlp-with-pd))
        (simple-service 'tlp-pd-polkit-action polkit-service-type
                        (list tlp-with-pd))))
