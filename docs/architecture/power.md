# Power Management

Laptop 的 AC/BAT 功耗控制（离电省电）与桌面 power-profile 控件的后端。

## Owner 与范围

- **唯一 owner**：`(guixcfg system power)`（`modules/guixcfg/system/power.scm`）。
  所有 AC/BAT 功耗策略集中于此，变更整机功耗行为只改这里。
- **host gating**：只有 laptop host
  （`(guixcfg hosts lenovo-legion-y7000p)`）消费 `%laptop-power-services`；
  VM / 非笔记本 host 不引用该模块（零 power closure），与 NVIDIA
  adapter 的 gating 同构。
- **官方机制**：TLP 是 pinned Guix 的官方 `tlp-service-type`
  （`(gnu services pm)`）；本仓库只提供 machine policy
  （`tlp-configuration` 的显式字段），不重写 TLP 逻辑。

## 两个组件

| 组件 | 提供者 | 作用 |
|---|---|---|
| TLP | pinned Guix `tlp-service-type`（1.9.0） | AC/BAT 自动切换的功耗策略：CPU EPP/boost、PCIe ASPM、runtime PM、USB autosuspend、WiFi、音频、disk |
| tlp-pd | virelith channel 的 `tlp-with-pd`（TLP 1.9 自带的 profiles daemon） | 提供 PPD 的 D-Bus 接口 `org.freedesktop.UPower.PowerProfiles`（+ legacy `net.hadess.PowerProfiles`），后端仍是 TLP |

`tlp-pd` 让 Noctalia / GNOME / KDE 等桌面的 power-profile 控件可用：
三个 profile（performance / balanced / power-saver）经 `tlp <profile>`
应用到 TLP 的 `_ON_AC` / `_ON_BAT` / `_ON_SAV` 设置。TLP 自身负责
离电自动切换（插电 performance、离电 balanced；用户手选 power-saver
则在电源变化时保持）。

GNU Guix 的官方 `tlp` 包只跑 `make install-tlp`，不产出 `tlp-pd`；
virelith 的 `tlp-with-pd` 继承官方包并额外 `make install-pd`，同时为
Python daemon（dbus-python + PyGObject）重写 shebang 并 wrap
`GUIX_PYTHONPATH` / `GI_TYPELIB_PATH`。升级 TLP 时随 channel 一起验证。

## Single owner 不变式

**不得同时运行 `power-profiles-daemon`（PPD）**：它与 `tlp-pd` 争用同一
system bus name（`org.freedesktop.UPower.PowerProfiles`），且 TLP 1.6+
检测到运行中的 PPD 时会主动让出 4 项重叠设置
（platform profile / CPU EPP / boost / AMDGPU ABM），造成不可预测结果。
本仓库因此不引入 PPD，`tests/test-power.scm` 固定该不变量。

## 服务构成

`%laptop-power-services` 贡献：

- `(service tlp-service-type %laptop-tlp-configuration)`——含 udev AC/BAT
  规则、activation 写 `/etc/tlp.conf`；
- `tlp-pd` root shepherd 服务（`requirement '(dbus-system)`，前台常驻）；
- `tlp-with-pd` 扩进 `dbus-root-service-type`（发布
  `share/dbus-1/system.d` 的 D-Bus system policy）；
- `tlp-with-pd` 扩进 `polkit-service-type`（发布
  `share/polkit-1/actions/tlp-pd.policy`，profile 切换经 polkit 授权）。

## TLP 机器策略

`%laptop-tlp-configuration` 只显式化需要固定的机器策略，其余交给 TLP
自身优化过的 `defaults.conf`（`tlp-configuration` 的 `maybe-*` 字段未
设置时不写入 `/etc/tlp.conf`）：

- `cpu-energy-perf-policy-on-ac "balance_performance"` /
  `on-bat "balance_power"`（intel_pstate EPP，与 TLP 默认一致，显式化）；
- `cpu-boost-on-ac? #t` / `on-bat? #f`（离电关睿频，主要 CPU 功耗来源）；
- `disks-devices '("nvme0n1" "sda")`——**必须显式设置**：Guix
  `tlp-configuration` 的 record 默认是 `("sda")`，会覆盖 TLP default 的
  `"nvme0n1 sda"`，而本机从 NVMe 启动。

## 运行期验证（实机，非 VM）

- `sudo tlp-stat -s -b`：确认模式切换（AC/BAT）与 profile；
- `busctl --system introspect org.freedesktop.UPower.PowerProfiles \\
   /org/freedesktop/UPower/PowerProfiles`：确认 `tlp-pd` 已 claim 名称；
- `powerprofilesctl` 应**不存在**（PPD 不安装）；
- `cat /sys/class/power_supply/BAT1/power_now`（拔插电源前后）评估效果；
- `dmesg | grep -i nvme`：排查 PCIe ASPM 是否引发盘错误。

## 非目标（本阶段不做）

- 电池充电养护（`conservation_mode`）：本机由 `ideapad_laptop` 暴露
  `VPC2004/conservation_mode`，非标准 `charge_control_*`，TLP 的
  `START/STOP_CHARGE_THRESH_BAT0` 走不到；如需另行评估独立机制。
- `thermald`（热管理）与空闲/合盖挂起（elogind `idle-action` /
  `handle-lid-switch`）：属独立 concern，未纳入。
