# Mihomo 系统透明代理（Phase 1）

> 全链路横切总结（与 DNS 的协作语义、设计决策表、降级矩阵、
> 运维手册）见 `network.md`；本文件只讲代理分领域细节。

Mihomo 作为系统级透明代理，由 Guix System + Shepherd 独占生命周期。
binary 唯一 owner 是 Rosenthal channel 的 `mihomo` package（pin
1.19.32，`(rosenthal packages networking)`，build tag `with_gvisor`）。

## Ownership 边界

```
Guix / Shepherd
  └── Mihomo process lifecycle
       ├── TUN（mixed stack，mihomo0）
       ├── route / auto-redirect（Mihomo 自建 nftables 表 "mihomo"）
       ├── proxy runtime（原生 http proxy-provider）
       └── Clash external-controller（127.0.0.1:9090，secret 置空）

系统 DNS（docs/architecture/dns.md）
  └── SmartDNS 独占 127.0.0.1:53（独立于 Mihomo）
      fixed → AliDNS IP DoH；dhcp → NM dnsmasq:15353 → DHCP DNS
      Mihomo 不监听 53、不解析 DNS、不劫持 DNS

Noctalia Mihomo Control
  └── 仅经 Clash REST API 控制运行中的 Mihomo
      不启动/停止/管理 TUN/更新 binary
```

## 设计决策：自建 thin service（方案 B）

不复用 Rosenthal `clash-service-type`（`(rosenthal services
child-error)`），只复用其 `mihomo` package。三处实质语义差异：

1. **运行时 secret-bearing 配置路径**：Rosenthal 只支持 store
   file-like → symlink 到 `-d/config.yaml`；本服务用
   `-f /run/mihomo/config.yaml`（materializer 合成）。
2. **依赖注入**：Rosenthal shepherd requirement 硬编码
   `'(loopback networking)`；本服务显式依赖
   `ordinary-secrets-ready`（经 materializer）与
   `mihomo-config-ready`——声明式 ordering，无启动竞态。
3. **providers 子目录持久化**：Rosenthal 无此概念。

Rosenthal 通用改进（`config-file` / `shepherd-requirement` 字段，
默认行为零变化）记录为未来上游 PR 目标；采纳并随常规 channel
更新 repin 后，本模块可按官方化流程删除（AGENT.md §7）。

## Service dependency graph

```
guixcfg-secrets-ordinary-deploy（one-shot；provision ordinary-secrets-ready）
    requirement: persistent-state-ready
        │
        ▼
mihomo-config（one-shot materializer；provision mihomo-config-ready）
    requirement: ordinary-secrets-ready
        │                          │
        ▼                          ▼
mihomo（daemon）
    requirement: loopback networking mihomo-config-ready
    start: mihomo -d /var/lib/clash -f /run/mihomo/config.yaml（root，clash 组）
    stop:  make-kill-destructor（SIGTERM → Mihomo 自清理 TUN/route/nftables）
    respawn: shepherd 默认 #t
```

boot 时序：activation（数据目录/backing 0700）→ file-systems
（bind providers）→ persistent-state-ready → secrets ordinary deploy
→ mihomo-config →（loopback/networking 齐）→ mihomo 启动。

## 路径与状态

| 路径 | 类别 | 内容 / 权限 |
|---|---|---|
| `/gnu/store/...-mihomo-template.yaml` | immutable | 公开模板（四个占位符各恰好一次，无 secret） |
| `/gnu/store/...-mihomo-1.19.33` | immutable | binary（Guix 唯一 owner；无 self-update） |
| `/run/guixcfg-secrets-ordinary/system/mihomo-source-*` | runtime secret | 每个源一份 age 明文（`.url` 或 `.file`），root 0400 |
| `/run/mihomo/` | runtime | root 0700（materializer 创建） |
| `/run/mihomo/config.yaml` | runtime | 模板 + 各源生成的 providers/groups，root 0600，原子写 |
| `/var/lib/clash/providers/<name>.yaml` | persistent（machine-state bind） | 每个 HTTP 源的 mihomo provider cache（0644，靠 0700 目录隔离） |
| `/var/lib/clash/subscriptions/<name>.yaml` | persistent（machine-state bind） | materializer 从 file 源 age 明文生成的 provider YAML（0600） |
| `/var/lib/clash/cache.db` | persistent（machine-state bind） | profile.store-selected（默认 true）落盘点（VM 实测：`-d/cache.db`，含 selected proxy/subscription-info/ETag）——**选中节点/组状态跨 boot 保留**（2026-08-28 起整体 bind `-d`，见下） |
| `/var/lib/clash/`（除 providers、cache.db 外） | persistent（同上） | 随 `-d` 整体 bind；config.yaml 不存在于 -d（`-f` 指定） |
| `/var/log/mihomo.log` | ephemeral | shepherd log-file，root 0640 |

machine-state rule：`/persist/system/state/mihomo/clash` →
bind → `/var/lib/clash`（**整个 -d 数据目录**）。rule 声明
`owner root` / `mode 0700`，由通用 persistence projection 与
mihomo activation 两侧幂等强制（Mihomo 以 0644 写 provider cache
文件，隔离靠不可遍历的 0700 parent）。整体 bind 的理由：providers
cache 与 cache.db（选中节点/组状态）都是 machine-owned mutable
state，都应在重启后保留；machine-state 只支持 bind-directory
（single-file bind 不是仓库标准机制，AGENT.md §12），`-d` 整体
bind 是覆盖两者的最小单一规则（2026-08-28：此前只 bind providers
时选中节点每 boot 重置）。

## 多订阅源（SCM 声明 + 每源一个 age）

源清单的 authority 是
`modules/guixcfg/system/mihomo/sources.scm` 的 `%mihomo-sources`。每个
`mihomo-source` 对应**一个 age 文件**，明文只能是：

- `kind = 'http`：一个 http(s) URL；
- `kind = 'file`：一份 mihomo provider YAML 内容（含 `proxies:`）。

示例：

```scheme
(define %mihomo-sources
  (list
   ;; 当前机场源：age 明文是一个订阅 URL。
   (mihomo-source "kuromis" 'http
                  (local-file "secrets/kuromis.http.age" "kuromis.http.age"))

   ;; 本地 provider：age 明文是一份 provider YAML。
   (mihomo-source "edge" 'file
                  (local-file "secrets/ordchaos-edge.file.age" "ordchaos-edge.file.age"))

   ;; 第二个 HTTP 源示例：
   ;; (mihomo-source "backup" 'http
   ;;                (local-file "secrets/backup.url.age" "backup.url.age"))
   ))
```

新增源：

1. 为**单个 URL 或单份 provider YAML 内容**创建一份 age 密文，放在
   `modules/guixcfg/system/mihomo/secrets/`；
2. 在 `%mihomo-sources` 加一条 `mihomo-source`，显式指定 age 文件与
   kind；
3. `blue reconfigure` / `herd restart mihomo`。

`target-name` 不写时自动派生：

```text
http → mihomo-source-<name>.url
file → mihomo-source-<name>.file
```

运行期路径由 declared target-name 经 `runtime-secret-target` 派生，
materializer 逐个读取后生成：

- `proxy-providers.provider-<name>`：HTTP 源（`type: http`，缓存
  `./providers/provider-<name>.yaml`，interval 3600s，`proxy: DIRECT`）
  或文件源（`type: file`）；
- `proxy-groups.<name>`：`select` 组，`use: [provider-<name>]`；
- 顶层 `PROXY`：`select` 组，成员为所有 `<name>` 子组加 `DIRECT`；
  规则 `MATCH,PROXY` 指向它。

**routing**：只有 `<name>` 子组和顶层 `PROXY`；不按 UDP/TCP 协议
拆分。每个 age 的 provider 是一个子组，顶层 `PROXY` 选择子组作为
提供方。

文件源：

- age 明文必须是 mihomo proxy-provider YAML（含 `proxies:`），不是完整
  Clash 配置；
- materializer 把它原子写到
  `/var/lib/clash/subscriptions/<name>.yaml`（0600，父目录 0700）；
  provider 路径由 Guile 生成，不需要在 SCM 里写路径；
- 修改文件内容 = 替换 age 密文后 reconfigure/restart，不要直接编辑
  运行期生成的 `subscriptions/*.yaml`；
- Noctalia 的 Update subscriptions 只刷新 `vehicleType == "HTTP"` 的
  provider，文件源自动跳过。

**每个 age 的 provider 是一个子策略组**：`<name>` 负责在该
provider 的节点里选择；顶层 `PROXY` 只选择 `<name>` 子组，不直接
暴露 provider 节点。

## secret 数据流与边界（诚实声明）

```
modules/guixcfg/system/mihomo/secrets/<source>.age
    （每个源一份 ciphertext：单 URL 或单 provider 文件内容；与 mihomo
      模块同置，单份全设备共用，可进 store）
    → boot：installed identity 解密（age；ordinary domain，不 gate login）
    → /run/guixcfg-secrets-ordinary/system/<target-name>（root 0400）
    → mihomo-config materializer：
        %mihomo-sources 逐个读取明文；HTTP 源剥除末尾单个 LF/CRLF 并
        校验 URL；file 源原子写到 subscriptions/<name>.yaml（0600）；
        生成 proxy-providers 与 <name> / PROXY groups；每个占位符恰好
        一次；tmp + fsync + atomic rename；/run/mihomo 0700、config
        0600
    → mihomo -f 读取 → 每个 HTTP 源拉取订阅（interval/cache/refresh
        由 Mihomo 维护）；文件源读取生成的 subscriptions/*.yaml
```

secret 泄漏面：

- **不进 Git**（只有 age ciphertext）；**不进 /gnu/store**（只有
  ciphertext 与占位符模板；materializer 只嵌入路径常量）；
- 不进 argv / environment（materializer 与 mihomo 均只传路径）；
- materializer 日志只报输出路径，不打印源明文/URL；
- **Mihomo provider fetch 失败时，上游实现会把完整 URL（含 query
  token）写入 error log**（VM 实测：`[Provider] <name> pull
  error: Get "http://…": EOF`）。当前接受该边界：日志 ephemeral
  且仅 root 可读（0640）。**不声称 secret“绝不落盘”。**

## controller

`external-controller: 127.0.0.1:9090`，`secret: ""`——当前单用户、
loopback-only 部署的明确选择。若未来监听非 loopback 或引入不受信任
本地用户，必须启用 controller secret。不配置 `SAFE_PATHS`，不扩大
controller 可读取配置的安全路径。

## DNS ownership 与边界

- **Mihomo 不再拥有 DNS**：模板没有 `dns:` 段，不监听 53，不做
  `dns-hijack`。应用 resolver 是独立的 SmartDNS（见 `dns.md`）；
- **SmartDNS** 绑定 127.0.0.1:53，fixed 模式只查 AliDNS IP DoH，
  dhcp 模式只查 NetworkManager dnsmasq (:15353)。模式由用户在
  Noctalia 面板显式选择，持久化在 `/var/lib/guixcfg-dns/mode`；
- **NetworkManager dnsmasq** 仍是当前 DHCP DNS 的 source；它不参与
  fixed 模式，没有跨模式 fallback；
- **递归切断**：SmartDNS（UID 974）与 dnsmasq（UID 985）均在
  `tun.exclude-uid` 中；sing-tun 以 `meta skuid`/owner 规则使它们的
  上游查询不进入 TUN；
- **TUN on/off**：只决定业务流量是否经过 mihomo；DNS 始终由 SmartDNS
  处理，不随 TUN 切换；
- `ipv6: false`：机场节点全是 v4，TUN 捕获的 v6 流量经节点无法到达
  目标 v6 地址；关闭后系统 v6 走原生路径绕过 Mihomo；
- 不做 Mihomo self-update（binary 归 Guix）；
- 不引入 geosite/geoip 规则系统（规则集为最小基础集 + sniffer）；
- **已知取舍**：Mihomo 关闭后，TUN 规则和流量代理消失，但 DNS 不再
  随之失败；域名规则依赖 sniffer，IP CIDR 规则基于 SmartDNS 返回的
  真实地址。

## 配置模板契约

`modules/guixcfg/system/mihomo/template.yaml`（public authority）：

- 占位符 `@@MIHOMO_PROXY_PROVIDERS@@`、`@@MIHOMO_PROXY_GROUPS@@`、
  `@@MIHOMO_NM_DNSMASQ_UID@@`、`@@MIHOMO_SMARTDNS_UID@@` 各恰好
  一次，模板不可直接运行；前两者由 `%mihomo-sources` 生成，UID 由
  `(guixcfg system dns nm-dnsmasq)` / `(guixcfg system dns smartdns)`
  注入；
- **没有 `dns` 段**；resolver 不在 mihomo 内；
- `tun`：mixed stack、auto-route/auto-redirect/auto-detect-interface、
  `exclude-uid`（nm-dnsmasq + smartdns）；
- `sniffer`：TLS/HTTP/QUIC 端口（DOMAIN/GEOSITE 分流前提）；
- provider/groups：由 `%mihomo-sources` 生成；每个源一个 provider 与
  `<name>` select 组，顶层 `PROXY` select 汇聚所有源 + `DIRECT`。
  HTTP 源 `proxy: DIRECT`、`interval: 3600`、health-check lazy；文件源
  `type: file`，materializer 生成的路径在 `-d` 下；
- 规则：私网/loopback/ULA → DIRECT；`cn-ip`
  （Loyalsoldier geoip 的 `cn.txt`，覆盖 47.96.0.0/11 等阿里云段）
