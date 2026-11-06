# System DNS ownership（SmartDNS + NetworkManager dnsmasq）

> 全链路横切总结见 `network.md`；Mihomo 的流量/TUN 细节见
> `mihomo.md`。本文件只讲 DNS ownership、模式选择与 resolver 语义。

## 目标链

应用 DNS 只有一个入口：独立于 Mihomo 的 SmartDNS。

```text
Applications
    ↓
/etc/resolv.conf（NetworkManager 写 nameserver 127.0.0.1）
    ↓
SmartDNS（127.0.0.1:53）
    ├─ fixed 模式：只查 AliDNS IP DoH
    └─ dhcp  模式：只查 127.0.0.1:15353
                       ↓
                 NetworkManager dnsmasq
                       ↓
                 当前 DHCP DNS
```

- SmartDNS 不依赖 Mihomo。Mihomo 崩溃时 DNS 继续工作。
- TUN on/off 不影响 resolver；TUN 只承载业务流量。
- SmartDNS 和 dnsmasq 的上游都以稳定 UID 运行，并被
  `tun.exclude-uid` 排除，避免 DNS → TUN 递归。
- 不使用 fake-ip；Mihomo 不再做 DNS，SmartDNS 返回真实 IP。

## 模式选择：手动、全局、持久

DNS 模式不是按 NetworkManager 连接自动推断的。它由用户在
Network Layer 面板的 DNS 卡片显式选择：

```text
Noctalia Network Layer
    ↓ 写 /var/lib/guixcfg-dns/mode（fixed|dhcp）
root mode applier
    ↓ 切换 SmartDNS 配置 + 重启 SmartDNS
```

- `mode` 文件是唯一的 desired state。
- `applied` / `status` 是 `/run` 下的模式应用反馈。
- `smartdns-status` 是 applier 扫描 `/proc` 得到的 SmartDNS 运行状态
  （running/stopped）；只用于 UI 展示，不参与模式决策。
- 模式文件不通过自定义 CLI 修改；没有 `guixcfg-dns-mode` 命令。
- 选择立即写入；root applier 监听文件变化并应用。
- 重启/断电后模式保留。

持久化与 Mihomo 当前节点选择同类：

```text
/var/lib/guixcfg-dns/mode
    ↓ machine-state bind
/persist/system/state/guixcfg-dns/mode
```

权限：

```text
/var/lib/guixcfg-dns/       root 0755
/var/lib/guixcfg-dns/mode   root 0666（用户可写；root applier 读取）
```

默认值：文件不存在时为 `fixed`，优先保证不会泄漏到 DHCP DNS。

## fixed 模式

```text
SmartDNS → AliDNS IP DoH
```

- 只配置 `server-https`。
- 不出现 `127.0.0.1:15353`。
- 没有 fallback、没有域名列表。
- DoH 失败即失败；不会偷偷用 DHCP DNS。
- 本地名字不解析；这是无域名列表模型的明确边界。

## dhcp 模式

```text
SmartDNS → 127.0.0.1:15353 → NM dnsmasq → 当前 DHCP DNS
```

- 只配置 `server 127.0.0.1:15353`。
- 不出现任何 DoH 上游。
- 没有 fallback 到 DoH。
- 本地名字由 DHCP DNS 自己回答；无域名列表。

## 配置

SmartDNS 固定绑定 loopback：

```text
bind 127.0.0.1:53
bind-tcp 127.0.0.1:53
user smartdns
cache-size 4096
speed-check-mode none
```

- fixed 只有 AliDNS IP DoH。
- dhcp 只有 NM dnsmasq。
- 两份配置是 store 内的静态文件；root applier 只切换
  `/run/guixcfg-dns/smartdns.conf` 软链接。
- 没有 `fallback`、`domain-rules`、`nameserver /domain/`。

## Ownership 分层

| 层 | owner | 形态 |
|---|---|---|
| 应用 resolver | SmartDNS | `127.0.0.1:53`，UID 984 |
| DHCP DNS source | NetworkManager dnsmasq | `127.0.0.1:15353`，UID 985 |
| DHCP DNS | 当前连接 | 由 NM/dnsmasq 提供，不写死 |
| 模式 desired state | 用户/面板 | `/var/lib/guixcfg-dns/mode` |
| 模式执行 | root applier | 切换配置、重启 SmartDNS |
| `/etc/resolv.conf` | NetworkManager | 写 `nameserver 127.0.0.1` |
| TUN / 流量 | Mihomo | DNS 关闭，只做 TUN/规则/代理 |
| DNS 控件 | Noctalia Network Layer | 两段模式选择器，无域名列表 |

## 递归切断与 UID

```text
SmartDNS UID 984   → TUN exclude
nm-dnsmasq UID 985 → TUN exclude
```

- SmartDNS 的 DoH 不进入 TUN，因此不依赖 Mihomo。
- dnsmasq 的 DHCP 上游不进入 TUN。
- Mihomo 的 TUN 不再设置 `dns-hijack`。

## 失败语义

| 故障 | 行为 |
|---|---|
| Mihomo 崩溃 | SmartDNS 继续解析；流量按 TUN 是否存活退化 |
| SmartDNS 崩溃 | DNS 失败；Shepherd respawn；不自动换模式 |
| fixed DoH 不可达 | DNS 失败；不回退 DHCP DNS |
| dhcp DNS 不可达 | DNS 失败；不回退 DoH |
| mode 文件非法 | root applier 忽略，保持已应用模式 |
| mode 切换失败 | `status` 记录错误；`applied` 不更新 |
| 面板无法写 mode 文件 | UI 显示错误；不假装成功 |

## 实施文件

- `modules/guixcfg/system/dns/smartdns.scm`
  - SmartDNS 账号/UID、两份配置、Shepherd 服务、mode applier、
    activation、machine-state rule。
- `modules/guixcfg/system/dns/nm-dnsmasq.scm`
  - dnsmasq 仍是 DHCP DNS source；:15353、UID 985。
- `modules/guixcfg/system/mihomo/template.yaml`
  - 删除 DNS 段与 dns-hijack；TUN exclude 两个 UID。
- `modules/guixcfg/system/mihomo/config.scm`
  - 两个 UID placeholder；materializer 必须同时替换。
- `modules/guixcfg/hosts/common.scm`
  - SmartDNS service、mode persistence rule。
- `custom-noctalia-plugins/network-layer`
  - DNS 卡片、mode 文件写入/状态读取。

## 验证

静态/机制：

- fixed 配置没有 15353；
- dhcp 配置没有 DoH；
- mode 文件是唯一 desired-state 输入；
- mihomo 无 DNS/listen/hijack；
- `exclude-uid` 同时包含 984/985；
- mode applier 的 `--check` 真实可执行。

运行时：

- `ss`：SmartDNS 53、dnsmasq 15353、mihomo 不监听 53；
- fixed：仅 DoH；无 15353 查询；
- dhcp：仅 dnsmasq；无 DoH；
- 面板切换后 `applied` 更新；
- 重启后模式保持；
- `herd stop mihomo` 后 DNS 仍可用。

## 已知边界

- fixed 模式下本地名字无法解析。
- fixed 模式如果当前连接仍提供 DHCP search domain，应用可能把
  短名字补全后发往 DoH；这是 `/etc/resolv.conf` 搜索域与 resolver
  的边界，当前不通过域名列表或额外 resolv.conf 管理解决。
- IPv6-only 连接没有独立模式判定；当前系统语义以 IPv4 为主。
