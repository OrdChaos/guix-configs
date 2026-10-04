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
  #:use-module (gnu services) ;service、simple-service
  #:use-module (gnu services base) ;udev-rules-service、file->udev-rule
  #:use-module (gnu services dbus) ;dbus-root-service-type、polkit-service-type
  #:use-module (gnu services pm) ;tlp-service-type、tlp-configuration
  #:use-module (gnu services shepherd) ;shepherd-service
  #:use-module (gnu packages glib) ;glib（gdbus：TLP -> tlp-pd 回调）
  #:use-module (guix gexp) ;file-append、program-file、mixed-text-file
  #:use-module (virelith packages tlp) ;tlp-with-pd
  #:export (%laptop-tlp-configuration %platform-profile-sync-service
                                      %laptop-power-services))

;; laptop TLP 机器策略。字段语义以 pinned Guix (gnu services pm) 为准；
;; 变更这里即改变整机 AC/BAT 功耗行为。
(define %laptop-tlp-configuration
  (tlp-configuration (tlp tlp-with-pd)
                     ;; intel_pstate EPP：插电放开性能（performance），离电偏向省电
                     ;; （balance_power）。其余 AC/BAT 差异（PCIe ASPM、SATA ALPM、disk
                     ;; APM、WiFi/audio power save、sched-powersave、EPB）沿用 TLP/
                     ;; Guix record 的成熟默认（AC 性能、BAT 省电），不重复声明。
                     (cpu-energy-perf-policy-on-ac "performance")
                     (cpu-energy-perf-policy-on-bat "balance_power")
                     ;; 睿频是 CPU 功耗的主要来源；离电关闭。
                     (cpu-boost-on-ac? #t)
                     (cpu-boost-on-bat? #f)
                     ;; TLP 的 Guix record 默认在 AC 写 RUNTIME_PM=on，会覆盖 Nonguix
                     ;; NVIDIA service 的 power/control=auto udev policy，使 Ada dGPU 无法
                     ;; RTD3。两种供电状态均保持 auto；nvidia 不得加入 driver blacklist。
                     (runtime-pm-on-ac "auto")
                     (runtime-pm-on-bat "auto")
                     (runtime-pm-all? #t)
                     ;; 本机启动盘是 NVMe（Guix record 默认只有 "sda"）。
                     (disks-devices '("nvme0n1" "sda"))))

;; tlp-pd：常驻 root 服务，claim PPD 的 system bus name。必须在
;; dbus-system 之后启动（否则 claim name 失败）。wrapper（virelith
;; 包）已注入 python/GI 与自身 sbin；TLP 在 profile 应用后必须用 gdbus
;; 调 SyncProfile 更新 PPD D-Bus 状态，所以显式提供 glib/bin。系统 profile
;; 本身不含 gdbus，缺少它会导致硬件 profile 已变、Noctalia 却显示旧值。
(define %tlp-pd-shepherd-service
  (shepherd-service (documentation
                     "TLP profiles daemon (org.freedesktop.UPower.PowerProfiles API).")
                    (provision '(tlp-pd))
                    (requirement '(dbus-system))
                    (start #~(make-forkexec-constructor (list #$(file-append
                                                                 tlp-with-pd
                                                                 "/sbin/tlp-pd"))
                                                        #:environment-variables
                                                        (list (string-append
                                                               "PATH="
                                                               #$(file-append (gexp-input
                                                                               glib
                                                                               "bin")
                                                                  "/bin")
                                                               ":/run/current-system/profile/bin"))))
                    (stop #~(make-kill-destructor))))

;; fn+q（EC 热模式）→ 桌面面板同步的 THIN ADAPTER（docs/architecture/
;; power.md）。硬件渠道：Lenovo Legion 的 fn+q 由 lenovo-wmi-gamezone（本机
;; platform-profile provider）或 ideapad-laptop 经 platform_profile_notify()
;; 通知，内核对该 platform-profile class device 发 KOBJ_CHANGE uevent。tlp-pd
;; 自身不监听 platform_profile，只在 TLP 应用/回调时更新 ActiveProfile，因此
;; 不经桥接时桌面面板不会跟随 fn+q。helper 把硬件 profile 反映射为 TLP
;; profile 并调 tlp-pd 的 SyncProfile（只更新内部状态并发 PropertiesChanged，
;; 不回写 platform_profile，故与 TLP 正向写入不构成环）。
;; 映射与 TLP defaults.conf 正向一致（_ON_AC=performance、_ON_BAT=balanced、
;; _ON_SAV=low-power）：low-power↔power-saver、balanced↔balanced、
;; performance/max-power→performance；custom 不映射（保持面板不动）。
(define %platform-profile-sync-program
  (program-file "platform-profile-sync"
                #~(begin
                    (use-modules (ice-9 rdelim)) ;read-line
                    (define (read-platform-profile)
                      (call-with-input-file "/sys/firmware/acpi/platform_profile"
                        (lambda (port)
                          (let ((line (read-line port)))
                            (if (eof-object? line) "" line)))))
                    (define (tlp-profile platform-profile)
                      (cond
                        ((string=? platform-profile "low-power")
                         "power-saver")
                        ((string=? platform-profile "balanced")
                         "balanced")
                        ((string=? platform-profile "performance")
                         "performance")
                        ((string=? platform-profile "max-power")
                         "performance")
                        (else #f)))
                    (let ((profile (tlp-profile (read-platform-profile))))
                      (when profile
                        (system* #$(file-append (gexp-input glib "bin")
                                                "/bin/gdbus")
                         "call"
                         "-y"
                         "-d"
                         "org.freedesktop.UPower.PowerProfiles"
                         "-o"
                         "/org/freedesktop/UPower/PowerProfiles"
                         "-m"
                         "org.freedesktop.UPower.PowerProfiles.SyncProfile"
                         profile))
                      (exit 0)))))

(define %platform-profile-sync-udev-rule
  (file->udev-rule "90-power-profile-sync.rules"
                   (mixed-text-file "90-power-profile-sync.rules"
                    "# (guixcfg system power) reflect EC/fn+q platform-profile changes
"
                    "# into tlp-pd's PowerProfiles ActiveProfile for the desktop panel.
"
                    "ACTION==\"change\", SUBSYSTEM==\"platform-profile\", RUN+=\""
                    %platform-profile-sync-program
                    "\"\n")))

(define %platform-profile-sync-service
  (udev-rules-service 'power-profile-sync %platform-profile-sync-udev-rule))

;; laptop power services（host 经 additional-system-services 消费）：
;;   - TLP 服务（含 udev AC/BAT 规则与 activation 写 /etc/tlp.conf）；
;;   - tlp-pd shepherd 服务；
;;   - tlp-with-pd 的 D-Bus system policy（dbus-root-service-type 收集
;;     share/dbus-1/system.d）；
;;   - tlp-with-pd 的 polkit action（polkit-service-type 收集
;;     share/polkit-1/actions）；
;;   - platform-profile → tlp-pd 同步 udev 规则（fn+q ↔ 面板）。
(define %laptop-power-services
  (list (service tlp-service-type %laptop-tlp-configuration)
        (simple-service 'tlp-pd shepherd-root-service-type
                        (list %tlp-pd-shepherd-service))
        (simple-service 'tlp-pd-dbus-policy dbus-root-service-type
                        (list tlp-with-pd))
        (simple-service 'tlp-pd-polkit-action polkit-service-type
                        (list tlp-with-pd)) %platform-profile-sync-service))
