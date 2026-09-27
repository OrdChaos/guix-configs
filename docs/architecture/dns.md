# System DNS ownership（Phase 2）

> 全链路横切总结（与 mihomo 的协作语义、设计决策表、降级矩阵、
> 运维手册）见 `network.md`；本文件只讲 DNS 分领域细节。

## 目标链

```
Applications
    ↓
/etc/resolv.conf（静态，repo authority：nameserver 127.0.0.1）
    ↓
127.0.0.1:53（SmartDNS 刻意不绑 [::1]——v4-literal resolver 无 v6
消费者，且 [::1] bind 会在 IPv6 被禁用时让整个 DNS 服务启动失败）
    ↓
SmartDNS（唯一 system resolver：cache / upstream selection / policy）
    ↓
固定 explicit upstream（223.5.5.5、119.29.29.29，IP literal）——
查询**直连**发出（DIRECT 规则）：这是**自举必需**——机场节点服务器
是域名，mihomo 拨号前经 SmartDNS 解析节点域名；上游若走节点 =
死锁（2026-08-28 重启后实测 all proxies timeout）。附带：DNS 不随
节点存亡，TUN off 时退化为直连机器（network.md §7）。
```

Mihomo 只负责 TUN / traffic routing / proxy policy——不做 DNS
（`dns-hijack: []`、无 dns 段、无 fake-ip）。

## Ownership 分层

| 层 | owner | 形态 |
|---|---|---|
| `/etc/resolv.conf` | `(guixcfg system dns ownership)`（静态，唯一 writer） | ephemeral 普通文件（etc-service 声明式，每 boot 重建）；NM/openresolv 均不再触碰 |
| `/etc/resolvconf.conf` | `(guixcfg system dns ownership)` | 把 openresolv libc subscriber 的输出重定向到 `/run/resolvconf/resolv.conf`；其余 subscriber（named/dnsmasq/unbound/systemd-resolved/…）显式关闭 |
| DHCP DNS | NetworkManager（经 resolvconf -a） | **不丢弃**：以 `/run/resolvconf/resolv.conf` 的形式保留；root-owned regular `dns-change` dispatcher 严格解析 IPv4 `nameserver` 行并原子投影到 `/run/smartdns/dhcp-upstreams.conf`；openresolv 合并当前所有非 private 条目并按 metric 排序 |
| SmartDNS 进程 | `(guixcfg system dns smartdns)`（thin service，Guix smartdns 47 包） | Shepherd 管理；loopback-only 监听；固定 upstream 为默认，DHCP DNS 仅 `-fallback`；cache 仅内存 |
| upstream 出口 | `(guixcfg system mihomo config)` 模板 rules | `IP-CIDR,<upstream>/32,DIRECT,no-resolve`——上游直连（自举必需：节点服务器是域名，上游走节点 = 解析死锁；附带 DNS 不随节点存亡） |

## 数据流（当前真实）

```
DHCP（SLIRP 10.0.2.3 / 现实网络）
  ↓ NetworkManager（rc-manager=resolvconf，编译期默认）
  ↓ resolvconf -a（openresolv 3.17.4）
/run/resolvconf/keys + /run/resolvconf/resolv.conf（libc subscriber 重定向输出）
  ↓ NetworkManager dns-change dispatcher
/run/smartdns/dhcp-upstreams.conf（严格 IPv4、原子写入、`server <ip> -fallback`）
  ↓ herd reload smartdns（仅服务已运行时；首次启动直接读 include）
```

```
Applications
  ↓ glibc/nscd
/etc/resolv.conf（静态 nameserver 127.0.0.1）
  ↓
SmartDNS @127.0.0.1:53（cache → prefetch → serve-expired）
  ↓ DIRECT（mihomo 规则按上游 IP 直连）
223.5.5.5 / 119.29.29.29（固定默认 upstream）
  ↓ 默认上游不可达时
DHCP DNS（动态 fallback；认证前 captive portal 可用）
```

## 决策记录

- **resolvconf-bootstrap 退役**：其存在理由是接管 Guix nscd
  placeholder 的 `/etc/resolv.conf` ownership；静态 ownership 后该
  问题消失（libc subscriber 输出已重定向 /run，NM 不再写 /etc）。
- **openresolv 保留**：不再写 `/etc/resolv.conf`，改为产出 DHCP DNS 的
  `/run` metadata；NetworkManager 官方 `dns-change` dispatcher 严格提取 IPv4
  nameserver，原子生成 SmartDNS 的 `-fallback` include 并 SIGHUP 重载。其 hook
  必须是 root-owned regular file（NM 拒绝符号链接），因此由独立的 one-shot
  Shepherd 服务 `smartdns-dhcp-setup` 在真实 root 上原子写入调用 store
  program 的最小 wrapper 并物化 include；`smartdns` 依赖它。setup 必须跑在
  service start（不能在 shepherd 加载 service 文件时或在 boot activation 里
  嵌套 `system*`——2026-09-28 部署世代因此在 shepherd 启动前死锁挂起）。
  openresolv 会合并当前所有非 private
  条目并按 metric 排序，故 Wi-Fi、有线和多个有线连接的全局有效 DNS 都进入 fallback。
  这样 captive portal 认证前能使用本地 DHCP DNS，正常网络仍优先固定上游。
- **固定 upstream 用 IP literal**：无 hostname bootstrap 路径，也
  不经过 SLIRP 的 10.0.2.3——宿主 Fake-IP 污染被彻底隔离（此前
  guest 收到的 198.18.0.x 来自宿主 resolver，本链不再经过它）。
- **failure semantics**：SmartDNS crash → `/etc/resolv.conf` 仍指
  localhost → DNS unavailable（fail-closed；不绕过 resolver）；respawn 默认开。
  固定上游不可达时 SmartDNS 会使用当前 DHCP fallback；无 DHCP DNS 时查询
  SERVFAIL，恢复后自动可用（VM 实测 smartdns 47）。
- **cache persistence**：v1 不持久化，配置文件显式 `cache-persist no`
  （上游默认是 auto：cache-file 位置空闲 >128MB 时自动持久化到
  `/var/cache/smartdns.cache`；丢失代价 = 首查稍慢）。未来若需要：
  `cache-file /var/lib/smartdns/cache.db` + machine-state bind
  `/var/lib/smartdns`（目录级，绕开 single-file bind 限制）。

## 实施文件

- `modules/guixcfg/system/dns/ownership.scm`（静态 resolv.conf + resolvconf
  重定向 + `%dhcp-dns-metadata-path`）
- `modules/guixcfg/system/dns/smartdns.scm`（thin service + v1 配置）
- `modules/guixcfg/system/mihomo/template.yaml`（upstream DIRECT 规则）
- 删除 `modules/guixcfg/system/resolvconf.scm` 与其测试
- `tests/test-smartdns.scm`（S1-S7）
