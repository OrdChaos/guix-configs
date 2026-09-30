# Bluetooth

Laptop 的 Bluetooth userspace（BlueZ）与配对状态持久化。

## 边界：kernel side vs userspace

这台机器是 Intel AX211（USB `8087:0033`，CNVi）。**kernel side 不属本仓库
模块**，由内核平台层提供且实测正常：

- 驱动模块 `btusb` / `btintel`（`(gnu services linux)` 无关，来自 nonguix
  `linux-7.2` 的 kernel config：`CONFIG_BT_HCIBTUSB=m`、`CONFIG_BT_INTEL=m`
  等）；
- firmware `intel/ibt-0041-0041.{sfi,ddc}`（`%kernel-firmware` =
  nonguix `linux-firmware`）；
- 结果：`hci0` 已注册、`rfkill` 未 block、`btusb` 正常绑定。

因此“蓝牙驱动不正常”的根因从来不是驱动：此前仓库**完全没有
`bluetooth-service-type`**，所以没有 `bluetoothd`、没有 `org.bluez`
D-Bus 服务、没有 `bluetoothctl`，桌面（Noctalia 的 bluetooth widget）
自然无法使用。

## Owner 与范围

- **唯一 owner**：`(guixcfg system bluetooth)`
  （`modules/guixcfg/system/bluetooth.scm`）。
- **host gating**：只有 laptop host
  （`(guixcfg hosts lenovo-legion-y7000p)`）消费 `%laptop-bluetooth-services`；
  VM / 非笔记本 host 不引用本模块（零 BlueZ closure），与
  `(guixcfg system power)` / `(guixcfg system graphics nvidia)` 同构。
- **官方机制**：使用 pinned Guix 的官方 `bluetooth-service-type`
  （`(gnu services desktop)`）。它提供：`bluetoothd` shepherd 服务、
  bluez 的 D-Bus system policy/activation（`org.bluez`）、bluez udev
  rules、`/etc/bluetooth/main.conf`。

## AutoEnable

`%laptop-bluetooth-configuration` 设 `(auto-enable? #t)` → `main.conf` 的
`[Policy] AutoEnable=true`：`bluetoothd` 启动时自动给控制器上电。默认
`#f` 时 adapter 保持 powered-off，桌面控件表现为蓝牙“不可用”。

## 配对状态持久化

BlueZ 的配对状态（link keys、已配对设备）位于 `/var/lib/bluetooth`。
本机是无状态根，若不持久化则每次启动丢失、需要重新配对。经 generic
machine-state-persistence 投影：

```text
/persist/system/state/bluetooth  →  /var/lib/bluetooth
```

（`%laptop-bluetooth-persistence-rule`，与 NetworkManager 连接 profile
同一机制；不新增第二套持久化框架。`tests/test-bluetooth.scm` 固定
laptop-only gating、AutoEnable、规则与 bind mount。）

## 运行期验证（实机）

- `busctl --system list | rg bluez`：应出现 `org.bluez`；
- `bluetoothctl show`：controller 已 powered、有 BD Address；
- `bluetoothctl scan on` / `pair`：可发现并配对。

## 非目标

- 音频（A2DP/HFP）由 BlueZ 提供 profile，实际音频路由属 PipeWire
  会话层，不在本模块；
- kernel driver/firmware（btusb/btintel/ibt-*）由内核平台层负责，
  本模块不重写。
