# System DNS ownership（mihomo + NetworkManager dnsmasq）

> 全链路横切总结（与 mihomo 的协作语义、设计决策表、降级矩阵、
> 运维手册）见 `network.md`；本文件只讲 DNS 分领域细节。

## 目标链

应用 DNS 只有一个入口：mihomo 的 loopback DNS。

```
Applications
    ↓
/etc/resolv.conf（NetworkManager 经 openresolv 写入 nameserver 127.0.0.1）
    ↓
mihomo DNS（127.0.0.1:53）
    ├─ 固定 AliDNS IP DoH（223.5.5.5 / 223.6.6.6）
    ├─ 连接失败 / NXDOMAIN / 空答案 / 私网 IP
    │      ↓
    │  127.0.0.1:15353（NetworkManager dnsmasq → 当前 DHCP DNS）
    └─ 两边都失败 → 正常返回失败（SERVFAIL/NXDOMAIN）
```

- TUN on/off 都走这条链；TUN 只决定业务流量是否进入 mihomo。
- 固定上游是**阿里云 AliDNS 的 IP DoH 端点**
  （`https://223.5.5.5/dns-query`、`https://223.6.6.6/dns-query`），
  直接 HTTPS 443；不使用 UDP/TCP 53（TUN 的 `dns-hijack` 会把 mihomo
  自己的 53 查询劫回自身），也不经代理。
- 不使用 fake-ip：`redir-host` 才能让“无解析”产生 fallback 信号；
  fake-ip 会在本地直接生成假 IP，绕过上游失败判断。
- 不维护域名列表：LAN 判断是 `fallback-filter.geoip-code: LAN`
  的**地址分类**，不是 `nameserver-policy` 的域名白名单。

## Ownership 分层

| 层 | owner | 形态 |
|---|---|---|
| `NetworkManager` dns 配置 | `network-manager-configuration` 的 `(dns "dnsmasq")`（host 装配） | 生成 `/etc/NetworkManager/NetworkManager.conf` 的 `[main] dns=dnsmasq`；NM 自己 exec dnsmasq |
| dnsmasq.d 配置 | `dnsmasq-configuration-files` 字段（host 装配）→ `(guixcfg system dns nm-dnsmasq)` | `file-union` 物化 `/etc/NetworkManager/dnsmasq.d/00-nm-dnsmasq-user.conf`（`user=nm-dnsmasq`）与 `10-listen-port.conf`（`port=15353`） |
| dnsmasq 运行账号 | `(guixcfg system dns nm-dnsmasq)` | 专用系统账号 `nm-dnsmasq`（显式 UID/GID 985）；经 `account-service-type` 贡献（非 `users` 字段） |
| `/etc/resolv.conf` | NetworkManager（rc-manager=resolvconf，编译期默认） | NM 经构建期烘焙的 openresolv 写入 `nameserver 127.0.0.1`；ephemeral root 中由 NM 运行时创建/拥有——**repo 不再声明** |
| mihomo DNS | `(guixcfg system mihomo config)` 模板 | 监听 `127.0.0.1:53`；`redir-host`；固定 AliDNS `nameserver`；`fallback`/`direct-nameserver` 指向 `127.0.0.1:15353`；`dns-hijack: any:53` 仍保留给进入 TUN 的外部 DNS |

## 为什么 mihomo 占 53、dnsmasq 退到 15353

mihomo 的 `fallback` 是“主上游无 IP 或失败时再查 fallback”；如果
fallback 写 `system`，而系统 resolver 又指向 mihomo，就会形成
`mihomo → system → mihomo` 的回路。因此 fallback 必须指向一个
**独立的、不会回到 mihomo 的 DHCP DNS 入口**：

- mihomo 独占 `127.0.0.1:53`，成为应用 DNS 的唯一入口；
- NetworkManager dnsmasq 改听 `127.0.0.1:15353`（高位端口，避开
  mDNS 的 5353），仍由 NM 提供当前 DHCP DNS；
- mihomo 的 `fallback` 与 `direct-nameserver` 都指向
  `127.0.0.1:15353`。

端口常量由 `(guixcfg system dns nm-dnsmasq)` 单一拥有
（`%nm-dnsmasq-port`），mihomo 模板中的 `15353` 由
`tests/test-nm-dnsmasq.scm` N2/N7 契约锁定。

## 递归切断（关键不变量）

TUN on 时 mihomo `auto-route` 把出站流量导进 TUN。dnsmasq 的上游
DHCP DNS 查询若不排除，会进入 TUN → 被 `dns-hijack: any:53` 捕获 →
mihomo DNS，形成递归。

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

- **SmartDNS 保持退役**：不引入额外 resolver 层；mihomo 的
  `fallback` 已经覆盖“固定 AliDNS 优先、DHCP 兜底”，且不需要域名列表。
- **固定 AliDNS IP DoH 作为唯一系统上游**：`223.5.5.5` /
  `223.6.6.6` 的 DoH 端点（TLS 证书含 IP）直接查询；不使用 DoH
  域名，也不需要额外 bootstrap。校园域 / captive portal 由 fallback
  的 DHCP DNS 兜底。
- **不用 fake-ip**：`redir-host` 保留真实 IP，TUN off 也能直连；
  fallback 的触发条件是“无 IP/失败”，fake-ip 会绕过它。
- **UID 必须显式固定**：ephemeral root 每 boot 重建 `/etc/passwd`，
  动态系统账号会漂移；显式 UID 同时被 `(gnu build accounts)` 分配器
  跳过，不会与其他系统账号冲突。
- **不做探测/轮询/selector**：所有 DNS 都先走固定 AliDNS；失败由
  mihomo 的 fallback 机制在请求内处理，不维护健康检查状态机。
- **TUN off 也先走固定 AliDNS**：这是“固定上游优先”的直接结果；DHCP
  DNS 只在 AliDNS 失败/无解析时使用。若需要 TUN off 完全回 DHCP，必须
  额外的状态切换，不属于本设计。

## 已知取舍

- **内部域名会先被发往公共 AliDNS**：LAN 名字通常得到 NXDOMAIN，再
  fallback 到 DHCP；存在首查延迟和内部名字泄漏。要避免只能维护域名
  列表或本地域名规则（本设计明确不做）。
- **AliDNS IP DoH 直连**：DoH 查询走 HTTPS 443，不经过代理；固定 IP
  避免域名 bootstrap 依赖。TLS 证书校验由 mihomo 负责（AliDNS 的
  证书包含 223.5.5.5/223.6.6.6）。
- **所有 DNS 都依赖 mihomo 进程**：mihomo 停止时 53 无人监听，DNS
  直接失败；这符合“两边都失败则正常失败”的语义。
- **没有 fake-ip 的远端解析**：代理拿到的是真实 IP，不是域名；
  anycast/CDN 场景可能不如 fake-ip 精确。

## 实施文件

- `modules/guixcfg/system/dns/nm-dnsmasq.scm`（账号/组/UID/端口/conf）
- `modules/guixcfg/hosts/vm.scm`、`modules/guixcfg/hosts/lenovo-legion-y7000p.scm`
  （`(dns "dnsmasq")` + `dnsmasq-configuration-files`）
- `modules/guixcfg/system/mihomo/template.yaml`（dns / redir-host /
  AliDNS / fallback / fallback-filter / dns-hijack / exclude-uid）
- `modules/guixcfg/system/mihomo/config.scm`（UID 占位符替换）
- `tests/test-nm-dnsmasq.scm`（N1-N7）
- `tests/test-mihomo.scm`（M7 DNS 契约）
