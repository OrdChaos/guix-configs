# System DNS ownership（NetworkManager dnsmasq + mihomo）

> 全链路横切总结（与 mihomo 的协作语义、设计决策表、降级矩阵、
> 运维手册）见 `network.md`；本文件只讲 DNS 分领域细节。

## 目标链

**TUN off**（无代理，基础联网）：

```
Applications
    ↓
/etc/resolv.conf（NetworkManager 经 openresolv 写入 nameserver 127.0.0.1）
    ↓
NetworkManager 自带 dnsmasq（127.0.0.1:53，NM 直接 exec 构建期烘焙的 store 二进制）
    ↓
DHCP-provided DNS（含校园域 / captive portal）
```

**TUN on**（mihomo 接管）：

```
Applications DNS（发给任意 :53 的非 loopback 目标）
    ↓ mihomo dns-hijack（any:53 + tcp://any:53）
    ↓ mihomo fake-ip DNS
    ├─ DIRECT / local → direct-nameserver: system
    │                   → /etc/resolv.conf 127.0.0.1 → NM dnsmasq → DHCP DNS
    └─ PROXY          → nameserver / proxy-server-nameserver（DoH）
```

`/etc/resolv.conf` 始终指向 NetworkManager dnsmasq；mihomo 的
`direct-nameserver: system` 因此回到「系统 resolver → dnsmasq → DHCP
DNS」，这是一个**被动**数据源，不发额外探测。

## Ownership 分层

| 层 | owner | 形态 |
|---|---|---|
| `NetworkManager` dns 配置 | `network-manager-configuration` 的 `(dns "dnsmasq")`（host 装配） | 生成 `/etc/NetworkManager/NetworkManager.conf` 的 `[main] dns=dnsmasq`；NM 自己 exec dnsmasq 并监听 127.0.0.1:53 |
| dnsmasq.d 配置 | `dnsmasq-configuration-files` 字段（host 装配）→ `(guixcfg system dns nm-dnsmasq)` | `file-union` 物化 `/etc/NetworkManager/dnsmasq.d/00-nm-dnsmasq-user.conf`（`user=nm-dnsmasq`） |
| dnsmasq 运行账号 | `(guixcfg system dns nm-dnsmasq)` | 专用系统账号 `nm-dnsmasq`（显式 UID/GID 985）；经 `account-service-type` 贡献（非 `users` 字段） |
| `/etc/resolv.conf` | NetworkManager（rc-manager=resolvconf，编译期默认） | NM 经构建期烘焙的 openresolv 写入 `nameserver 127.0.0.1`；ephemeral root 中由 NM 运行时创建/拥有——**repo 不再声明** |
| mihomo DNS | `(guixcfg system mihomo config)` 模板 | `dns.enable` + `enhanced-mode: fake-ip` + `dns-hijack: any:53`；DIRECT 经 `direct-nameserver: system`，代理侧经 DoH |

## 为什么 /etc/resolv.conf 归 NetworkManager

`dns=dnsmasq` 时 NM 的职责就是：自己跑 dnsmasq 并把 libc resolver 指向
它。pinned 的 network-manager package 以
`-Dconfig_dns_rc_manager_default=resolvconf` 构建，并烘焙了 openresolv
路径；因此 NM 调 `resolvconf` 写 `/etc/resolv.conf`。这是 pinned 原生
行为，repo 不自建第二套 glue：

- 删除旧的静态 `/etc/resolv.conf`（127.0.0.1 SmartDNS）与
  `/etc/resolvconf.conf`（重定向 set）etc-service 声明；
- 不由 repo 任何 activation 覆盖 `/etc/resolv.conf`；
- 不引入 standalone `dnsmasq-service-type`（避免 `:53` 双 owner）。

## 递归切断（关键不变量）

TUN on 时 mihomo `auto-route` 把出站流量导进 TUN。dnsmasq 的上游
DHCP DNS 查询若不排除，会进入 TUN → 被 `dns-hijack: any:53` 捕获 →
mihomo DNS → 回到 `direct-nameserver: system` → dnsmasq → 递归。

切断方式（mihomo 官方机制，非硬编码 IP）：

- dnsmasq 以专用 UID `nm-dnsmasq`（985）运行（privilege drop）；
- mihomo `tun.exclude-uid: [985]`——sing-tun 在 Linux 的
  `auto-redirect`/`auto-route` nftables 规则中以 `meta skuid`（iptables
  路径为 `-m owner --uid-owner`）对匹配 UID 直接 `return`，使 dnsmasq
  的上游流量**不进入 TUN**。

该机制与具体 DHCP DNS 地址、Wi-Fi/宿舍/热点/酒店无关，满足任意 DHCP
网络；UID 由 `(guixcfg system dns nm-dnsmasq)` 单一拥有，mihomo 模板经
`@@MIHOMO_NM_DNSMASQ_UID@@` 占位符注入同一值。

## 决策记录

- **SmartDNS 退役**：DNS 由 NetworkManager dnsmasq（基础）+ mihomo
  （TUN 接管）承担，SmartDNS service / DHCP fallback include /
  openresolv→/run 重定向 / NM dispatcher 全部删除。
- **固定 upstream IP 退役**：旧的 SmartDNS 固定上游
  （223.5.5.5、119.29.29.29）不再作为系统 resolver upstream。它们仅作为
  mihomo `default-nameserver` 的 DoH bootstrap 保留（mihomo 要求
  bootstrap 必须是 IP）；普通 DIRECT 解析经 `system`，不经过它们。
- **UID 必须显式固定**：ephemeral root 每 boot 重建 `/etc/passwd`，
  动态系统账号会漂移；显式 UID 同时被 `(gnu build accounts)` 分配器
  跳过，不会与其他系统账号冲突。
- **captive portal**：TUN off 时 `dnsmasq → DHCP DNS` 直接可达门户；
  TUN on 时 mihomo `direct-nameserver: system` 同样经 DHCP DNS 完成
  门户/校园域解析（无需 connectivity probe / polling / `dhcp://`）。
- **不再需要探测/轮询/selector**：连通性切换由「是否经 TUN」这一
  静态网络状态表达，不做 HTTP probe。

## 实施文件

- `modules/guixcfg/system/dns/nm-dnsmasq.scm`（账号/组/UID/conf + NM 配置片段）
- `modules/guixcfg/hosts/vm.scm`、`modules/guixcfg/hosts/lenovo-legion-y7000p.scm`
  （`(dns "dnsmasq")` + `dnsmasq-configuration-files`）
- `modules/guixcfg/system/mihomo/template.yaml`（dns / fake-ip / dns-hijack /
  exclude-uid / direct-nameserver）
- `modules/guixcfg/system/mihomo/config.scm`（UID 占位符替换）
- `tests/test-nm-dnsmasq.scm`（N1-N7）
- 删除（迁移前的 SmartDNS 控制平面）：旧 DNS ownership/smartdns 模块、
  `resolv.conf`/`resolvconf.conf`/`smartdns.conf` 静态文件、旧
  SmartDNS 测试文件。
