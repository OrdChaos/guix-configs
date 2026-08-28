# System DNS ownership（Phase 2）

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
固定 explicit upstream（223.5.5.5、119.29.29.29，IP literal）——查询
**经代理节点出口**发出（见下：宿主侧 fake-ip DNS 劫持明文 53，直连
只会拿到假 IP）
```

Mihomo 只负责 TUN / traffic routing / proxy policy——不做 DNS
（`dns-hijack: []`、无 dns 段、无 fake-ip）。

## Ownership 分层

| 层 | owner | 形态 |
|---|---|---|
| `/etc/resolv.conf` | `(guixcfg system dns ownership)`（静态，唯一 writer） | ephemeral 普通文件（etc-service 声明式，每 boot 重建）；NM/openresolv 均不再触碰 |
| `/etc/resolvconf.conf` | `(guixcfg system dns ownership)` | 把 openresolv libc subscriber 的输出重定向到 `/run/resolvconf/resolv.conf`；其余 subscriber（named/dnsmasq/unbound/systemd-resolved/…）显式关闭 |
| DHCP DNS | NetworkManager（经 resolvconf -a） | **不丢弃**：以 `/run/resolvconf/resolv.conf` 的形式保留为 upstream metadata——v1 只产出、SmartDNS 暂不消费；未来"DHCP DNS 作为上游"的 seam |
| SmartDNS 进程 | `(guixcfg system dns smartdns)`（thin service，Guix smartdns 47 包） | Shepherd 管理；loopback-only 监听；固定 upstream；cache 仅内存 |
| upstream 出口 | `(guixcfg system mihomo)` 模板 rules | **无 DIRECT 规则**——上游查询走 `MATCH,PROXY`（代理节点出口）。原因：宿主侧/路由器对明文 53 全局劫持（fake-ip DNS，返回 198.18.x / fdfe:dcba:9876::x），直连永远拿假 IP；节点死亡时 DNS 随之不可用，换活节点恢复（2026-08-28 VM 实测） |

## 数据流（当前真实）

```
DHCP（SLIRP 10.0.2.3 / 现实网络）
  ↓ NetworkManager（rc-manager=resolvconf，编译期默认）
  ↓ resolvconf -a（openresolv 3.17.4）
/run/resolvconf/keys + /run/resolvconf/resolv.conf（libc subscriber 重定向输出）
  （v1：metadata，无消费者）
```

```
Applications
  ↓ glibc/nscd
/etc/resolv.conf（静态 nameserver 127.0.0.1）
  ↓
SmartDNS @127.0.0.1:53（cache → prefetch → serve-expired）
  ↓ DIRECT（mihomo 规则按上游 IP 直连）
223.5.5.5 / 119.29.29.29（固定 upstream）
```

## 决策记录

- **resolvconf-bootstrap 退役**：其存在理由是接管 Guix nscd
  placeholder 的 `/etc/resolv.conf` ownership；静态 ownership 后该
  问题消失（libc subscriber 输出已重定向 /run，NM 不再写 /etc）。
- **openresolv 保留**：不再写 `/etc/resolv.conf`，改为产出 DHCP
  DNS 的 `/run` metadata——为未来"DHCP DNS 作为 SmartDNS 附加
  upstream"保留机制（届时 hook 产出 + SmartDNS config 再生成 +
  SIGHUP 重载），v1 不实现。
- **固定 upstream 用 IP literal**：无 hostname bootstrap 路径，也
  不经过 SLIRP 的 10.0.2.3——宿主 Fake-IP 污染被彻底隔离（此前
  guest 收到的 198.18.0.x 来自宿主 resolver，本链不再经过它）。
- **failure semantics**：SmartDNS crash → `/etc/resolv.conf` 仍指
  localhost → DNS unavailable（fail-closed，不做自动回退 DHCP
  DNS）；respawn 默认开；upstream 不可达时 daemon 正常运行、查询
  SERVFAIL、恢复后自动可用（VM 实测 smartdns 47）。
- **cache persistence**：v1 不持久化（cache-persist no；丢失代价 =
  首查稍慢）。未来若需要：`cache-file /var/lib/smartdns/cache.db`
  + machine-state bind `/var/lib/smartdns`（目录级，绕开 single-file
  bind 限制）。

## 实施文件

- `modules/guixcfg/system/dns/ownership.scm`（静态 resolv.conf + resolvconf
  重定向 + `%dhcp-dns-metadata-path`）
- `modules/guixcfg/system/dns/smartdns.scm`（thin service + v1 配置）
- `modules/guixcfg/system/mihomo/template.yaml`（upstream DIRECT 规则）
- 删除 `modules/guixcfg/system/resolvconf.scm` 与其测试
- `tests/test-smartdns.scm`（S1-S7）
