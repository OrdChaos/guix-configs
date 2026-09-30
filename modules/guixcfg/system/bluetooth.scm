;;; Laptop Bluetooth：BlueZ userspace + pairing-state persistence。
;;;
;;; 边界（先厘清“驱动”与“userspace”）：这台机器的 Bluetooth 是 Intel
;;; AX211（USB 8087:0033，挂在 CNVi）。kernel side 已由内核平台层提供：
;;; btusb/btintel 模块（nonguix linux-7.2 的 kernel config）+ linux-firmware
;;; 的 intel/ibt-0041-0041.{sfi,ddc}（%kernel-firmware）。实测 hci0 已注册、
;;; rfkill 未 block、btusb 绑定正常，因此“驱动”本身没有故障——缺的是
;;; userspace BlueZ：本仓库此前没有任何 bluetooth-service-type，所以
;;; org.bluez D-Bus 服务、bluetoothd、bluetoothctl 全部不存在，桌面
;;; （Noctalia 的 bluetooth widget）自然无法使用。
;;;
;;; ownership contract：Bluetooth 是 laptop-only 物理能力，由 laptop host
;;; 消费；VM / 非笔记本 host 不引用本模块（零 BlueZ closure），与
;;; (guixcfg system power) / (guixcfg system graphics nvidia) 的 gating 同构。
;;; 官方机制：使用 pinned Guix 的官方 bluetooth-service-type，不重写
;;; bluetoothd / D-Bus / udev 逻辑。
;;;
;;; 机器状态：BlueZ 的配对状态（link keys、已配对设备）位于
;;; /var/lib/bluetooth。本机是无状态根，若不持久化则每次启动丢失、需要
;;; 重新配对——故经 generic machine-state-persistence 投影到
;;; /persist/system/state/bluetooth（与 NetworkManager 连接 profile 同一
;;; 机制，不新增第二套持久化框架）。

(define-module (guixcfg system bluetooth)
               #:use-module (gnu services)         ; service
               #:use-module (gnu services desktop) ; bluetooth-service-type、bluetooth-configuration
               #:use-module (guixcfg system machine-state-persistence)
               #:export (%laptop-bluetooth-configuration
                         %laptop-bluetooth-persistence-rule
                         %laptop-bluetooth-services))

;; auto-enable? #f → main.conf 的 [Policy] AutoEnable=false：bluetoothd 启动
;; 后控制器保持 powered-off，由用户在桌面控件里按需开启（默认关闭策略）。
(define %laptop-bluetooth-configuration
  (bluetooth-configuration
   (auto-enable? #f)))

;; BlueZ pairing state：/persist/system/state/bluetooth → /var/lib/bluetooth
;; （root-owned machine state；consumer 是 daemon 运行期读取的标准位置）。
(define %laptop-bluetooth-persistence-rule
  (machine-state-persistence-rule
   (name 'bluetooth)
   (backing "bluetooth")
   (consumer "/var/lib/bluetooth")))

;; laptop Bluetooth system services（host 经 additional-system-services 消费）：
;;   - bluetoothd shepherd 服务；
;;   - bluez 的 D-Bus system policy/activation（org.bluez）；
;;   - bluez udev rules；
;;   - /etc/bluetooth/main.conf（AutoEnable=true）。
(define %laptop-bluetooth-services
  (list (service bluetooth-service-type %laptop-bluetooth-configuration)))
