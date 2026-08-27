# Mihomo 系统透明代理（Phase 1）

Mihomo 作为系统级透明代理，由 Guix System + Shepherd 独占生命周期。
binary 唯一 owner 是 Rosenthal channel 的 `mihomo` package（pin
1.19.30，`(rosenthal packages networking)`，build tag `with_gvisor`）。

## Ownership 边界

```
Guix / Shepherd
  └── Mihomo process lifecycle
       ├── TUN（mixed stack，mihomo0）
       ├── route / auto-redirect（Mihomo 自建 nftables 表 "mihomo"）
       ├── proxy runtime（原生 http proxy-provider）
       └── Clash external-controller（127.0.0.1:9090，secret 置空）

系统 DNS（Phase 1 不动）
  └── NetworkManager → openresolv(resolvconf) → /etc/resolv.conf

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
| `/gnu/store/...-mihomo-template.yaml` | immutable | 公开模板（占位符恰好一次，无 secret） |
| `/gnu/store/...-mihomo-1.19.30` | immutable | binary（Guix 唯一 owner；无 self-update） |
| `/run/guixcfg-secrets-ordinary/system/mihomo-subscription.url` | runtime secret | age 解密产物，root 0400 |
| `/run/mihomo/` | runtime | root 0700（materializer 创建） |
| `/run/mihomo/config.yaml` | runtime | 模板+URL 合成，root 0600，原子写 |
| `/var/lib/clash/providers/airport.yaml` | persistent（machine-state bind） | Mihomo 自维护 provider cache（0644，靠 0700 目录隔离） |
| `/var/lib/clash/cache.db` | ephemeral | profile.store-selected（默认 true）落盘点（VM 实测：启动即创建于 `-d/cache.db`，含 selected proxy/subscription-info/ETag——全部 reacquirable）。**Phase 1 不持久化**：位于 `-d` 根（不可子目录化），而 machine-state 机制只支持 bind-directory（single-file bind 不是仓库标准机制，AGENT.md §12）；选择状态每 boot 重置，可由 Noctalia 重新选择 |
| `/var/lib/clash/`（除 providers 外） | ephemeral | 不持久化；config.yaml 不存在于 -d（`-f` 指定） |
| `/var/log/mihomo.log` | ephemeral | shepherd log-file，root 0640 |

machine-state rule：`/persist/system/state/mihomo/providers` →
bind → `/var/lib/clash/providers`。**backing 与 consumer 均由
mihomo activation 强制 0700**（generic mechanism 只建 0755 目录；
Mihomo 以 0644 写 provider cache 文件，隔离靠不可遍历的 parent）。
不整体 bind `/var/lib/clash`。首次真实运行后再审计 `-d` 下的其它
状态文件（如 profile.store-selected 对应的 cache/state 路径），
按需增加精确 persistence——不预先持久化整个目录。

## secret 数据流与边界（诚实声明）

```
modules/guixcfg/system/mihomo/secrets/mihomo-subscription.url.age
    （ciphertext 与 mihomo 模块同置，单份全设备共用，可进 store）
    → boot：installed identity 解密（age；ordinary domain，不 gate login）
    → /run/guixcfg-secrets-ordinary/system/mihomo-subscription.url（root 0400）
    → mihomo-config materializer：
        读取模板与 secret 文件；剥除末尾单个 LF/CRLF；残留
        CR/LF/NUL → fail closed；严格 YAML 双引号转义；占位符必须
        恰好一次（缺失/重复 fail closed）；tmp + fsync + atomic
        rename；/run/mihomo 0700、config 0600
    → mihomo -f 读取 → 原生 http provider 拉取订阅（interval 调度、
        cache、controller refresh 全由 Mihomo 维护）
```

secret 泄漏面：

- **不进 Git**（只有 age ciphertext）；**不进 /gnu/store**（只有
  ciphertext 与占位符模板；materializer 只嵌入路径常量）；
- 不进 argv / environment（materializer 与 mihomo 均只传路径）；
- materializer 日志只报输出路径，不打印 URL；
- **Mihomo provider fetch 失败时，上游实现会把完整 URL（含 query
  token）写入 error log**（VM 实测：`[Provider] airport pull
  error: Get "http://…": EOF`）。当前接受该边界：日志 ephemeral
  且仅 root 可读（0640）。**不声称 secret“绝不落盘”。**

## controller

`external-controller: 127.0.0.1:9090`，`secret: ""`——当前单用户、
loopback-only 部署的明确选择。若未来监听非 loopback 或引入不受信任
本地用户，必须启用 controller secret。不配置 `SAFE_PATHS`，不扩大
controller 可读取配置的安全路径。

## Phase 1 边界（NON-GOALS）

- 不动 NetworkManager / openresolv / `/etc/resolv.conf`；
- `dns-hijack: []` 显式置空（Mihomo 默认 `0.0.0.0:53`，必须显式关）；
- 不启用 fake-ip；不做 SmartDNS；不做 DNS 分流；
- 不做 Mihomo self-update（binary 归 Guix）；
- 不引入 geosite/geoip 规则系统（规则集为最小基础集）。

## 配置模板契约

`modules/guixcfg/system/mihomo/template.yaml`（public authority）：

- 占位符 `@@MIHOMO_SUBSCRIPTION_URL@@` 恰好一次，模板不可直接运行；
- provider：`type: http`、`proxy: DIRECT`（订阅刷新不依赖代理组/
  节点可用性，VM 实测默认 tunnel 路由在节点全挂时无法刷新）、
  `interval: 3600`（秒；省略则无周期刷新）、health-check lazy；
- 规则：loopback/private/local → DIRECT，其余 → PROXY；
- secret 的 target-name 契约：`mihomo-subscription.url`（与
  `(guixcfg system mihomo config)` 的 `%mihomo-secret-path` 派生
  一致；decl 由 `(guixcfg system mihomo service)` 的
`%mihomo-secrets` 声明）。
