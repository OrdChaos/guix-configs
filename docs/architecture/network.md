# System networking architecture（网络全链路）

本文件是网络架构的**横切总结**：把 DNS ownership（Phase 2，见
`dns.md`）、Mihomo 透明代理（Phase 1，见 `mihomo.md`）、订阅 secret
链（见 `secrets.md`）与实测得到的宿主侧环境约束串成一张完整图。
组件细节以各分文件为准，本文件只讲全链路的**设计决策与实现方式**。

---

## 1. 全景图

```
┌─ 设备（VM / 笔记本，同一 repo 语义）─────────────────────────────┐
│                                                                 │
│  App（curl/guix/浏览器）                                        │
│    │ DNS: getaddrinfo → nscd ─→ 127.0.0.1:53                    │
│    │ TCP: 出站流量 ─→ 默认路由 ─→ TUN (mihomo0)                 │
│    ▼                      ▼                                     │
│  smartdns（唯一系统 resolver）   mihomo 规则引擎                  │
│    │ 固定上游 223.5.5.5/         │ loopback/私网/ULA → DIRECT    │
│    │ 119.29.29.29（IP literal）  │ 上游 DNS 查询 → DIRECT（自举） │
│    │                            │ 其余 → MATCH → PROXY[节点]    │
│    └──── 直连（DIRECT 规则） ───►│                                │
│                                  ▼                               │
│                           机场节点（v4-only，select 组）          │
│                                  │                               │
│              └── 节点出口：代理业务流量 ──────────────────────────┘
│                                                                 │
│  DIRECT 旁路：eth0 → SLIRP/上行 → 公网（上游 DNS 直连 + 私网；   │
│    其余公网直连不在设计内——见 §6 宿主侧约束与 §7 降级矩阵）       │
└─────────────────────────────────────────────────────────────────┘
```

一句话语义：**DNS 上游直连（自举必需），业务流量经机场节点；本地
流量 DIRECT（仅私网/loopback），其余公网直连在设计上不存在。**

---

## 2. 设计决策逐条（决策 → 理由 → 代价）

| # | 决策 | 理由 | 代价 / 边界 |
|---|---|---|---|
| D1 | `/etc/resolv.conf` 静态 `nameserver 127.0.0.1`，repo 是唯一 writer | 无状态根每 boot 重建 /etc；NM/openresolv 写入不可控；系统只需要一个 resolver | 换上游必须改 repo + reconfigure（有意为之） |
| D2 | SmartDNS 是唯一系统 resolver，**只绑 127.0.0.1:53，不绑 ::1** | resolver 面是 v4-literal；::1 无消费者却让服务存活依赖 IPv6（实测：IPv6 被禁用时整服务起不来 → DNS 全断） | 本机无 v6 递归入口——AAA A 查询都经 v4 通道，无实际损失 |
| D3 | 上游固定 IP literal（223.5.5.5 / 119.29.29.29），无 hostname bootstrap | 无解析鸡生蛋问题；上游选择是显式仓库决策 | 无自动选优/无测速（v1 最小集） |
| D4 | **上游查询直连**（模板含上游 `DIRECT,no-resolve` 规则） | **自举必需**：机场节点服务器是域名（oss-cn-*.toshiba-nvme.com），mihomo 拨号前经系统 DNS（SmartDNS）解析节点域名；上游若走节点 = 解析死锁（2026-08-28 重启后实测：SERVFAIL → all proxies timeout）。附带 DNS 不随节点存亡、TUN off 时退化为直连机器 | 直连 AliDNS 对被封域名仍被 GFW 污染——被封域名的解析+连接本来只有代理能救，接受为直连语义的固有边界 |
| D5 | mihomo 不做客户端 DNS：`dns-hijack: []`、无 dns 段、**全系统语义无 fake-ip** | DNS 归 SmartDNS 单一 owner；fake-ip 会制造"解析成功但连接失败"的不可审计态 | mihomo 自身解析（节点域名）经系统 DNS——正是 D4 直连的自举链条 |
| D6 | `ipv6: false`：TUN 不捕获 v6 | 机场节点全是 v4，TUN 承载 v6 也送不到目标（实测 AAAA 目标经节点秒断）；v6 归系统原生路径 | 不承诺 v6 代理；笔记本上行有 v6 时 v6 直连绕过代理（泄露面，知情接受）；VM（SLIRP 无 v6）上 v6-only 服务不可达（快速失败） |
| D7 | 订阅刷新走规则路由（**不设 `proxy: DIRECT`**） | 宿主直连出站不稳（实测 api.wd-purple.com 直连 EOF 掐断）；经节点才能拿到完整响应 | 节点全挂时刷新失败——provider 有 cache-first，换活节点后经 refresh API 恢复 |
| D8 | **TUN 是唯一流量入口**：无 mixed-port、无 HTTP_PROXY 系统代理语义 | 单入口 = 可审计、无静默旁路；透明代理下应用零配置 | TUN off = 无显式回退口（干净宿主下自动退化为直连机器，见 §7；不提供"半代理"中间态） |
| D9 | 节点选择是**运行时偏好**，repo 只声明 select 组 | 节点健康随机场变化，不是 declarative 事实 | 重启/换节点后选择持久化于 `/var/lib/clash` 缓存；repo 不 pin 节点 |
| D10 | DHCP DNS 不丢弃也不使用：openresolv 输出重定向到 `/run/resolvconf/resolv.conf` 作为 metadata | "未来 DHCP DNS 作为上游"的 seam；不消费 = 不引入不确定性 | metadata 暂无消费者 |
| D11 | resolvconf-bootstrap 退役 | 静态 resolv.conf 由 etc-service 每 boot 重建，无需 openresolv -u 接管 | — |
| D12 | 订阅密文与引用者同置（mihomo/secrets/），domain ordinary | secret taxonomy（secrets.md）；订阅不可用只影响刷新，节点仍可从本地 cache 工作 | 解密失败不阻塞登录、只降级订阅刷新 |
| D13 | 配置合成 fail-closed：placeholder 恰好一次、严格 YAML 转义、残留 CR/LF/NUL 拒绝 | 订阅 URL 是唯一 secret 注入点，坏输入必须失败而非产出可运行错配置 | 物化失败 → mihomo 起不来（显式失败优于静默错） |
| D14 | machine-state 只持久化 providers cache（bind-directory，root-owned） | 订阅拉取结果要跨 ephemeral root 保留；不持久化任何 config（config 是 repo authority） | 单目录 bind，不扩权 |
| D15 | controller loopback-only、无 secret | 控制面只给本机运维，不进网络面 | 需要本机 shell 才能换节点/刷新 |

---

## 3. 具体实现方式

### 3.1 DNS 层

| 组件 | 位置 | 实现要点 |
|---|---|---|
| 静态 resolv.conf | `modules/guixcfg/system/dns/ownership.scm` | `%system-resolv-conf`（plain-file `"nameserver 127.0.0.1\n"`）、`%dhcp-dns-metadata-path`（`/run/resolvconf/resolv.conf`）、`system-dns-etc-service` |
| resolvconf 重定向 | `modules/guixcfg/system/dns/resolvconf.conf` | `resolv_conf=/run/resolvconf/resolv.conf` + 全部非 libc subscriber 显式 `*_enabled=NO` |
| SmartDNS 服务 | `modules/guixcfg/system/dns/smartdns.scm` | thin service-type：provision `'(smartdns)`、requirement `'(loopback networking)`（**不依赖 mihomo**）、`smartdns -f -c <store conf>`、log-file `/var/log/smartdns.log` |
| SmartDNS 配置 | `modules/guixcfg/system/dns/smartdns.conf` | bind/bind-tcp 仅 127.0.0.1:53；上游 223.5.5.5、119.29.29.29；cache-size 8192；无 cache-persist、无测速/分流 |
| Host 装配 | `modules/guixcfg/hosts/vm.scm` | `(system-dns-etc-service)`、`(smartdns-service)`；NM `(shepherd-requirement '())` |

### 3.2 代理层

| 组件 | 位置 | 实现要点 |
|---|---|---|
| 模板 | `modules/guixcfg/system/mihomo/template.yaml` | TUN（mixed stack、auto-route/auto-redirect/auto-detect-interface、`dns-hijack: []`）、`ipv6: false`；规则 = 私网/loopback/ULA DIRECT + 上游 `IP-CIDR,<upstream>/32,DIRECT,no-resolve`（D4 自举）+ `MATCH,PROXY`；provider：原生 http、`interval: 3600`、lazy health-check、无 `proxy: DIRECT`（D7）；`@@MIHOMO_SUBSCRIPTION_URL@@` 占位符恰好一次 |
| 配置合成 | `modules/guixcfg/system/mihomo/config.scm` | `compose-mihomo-config`：模板 + `/run` 明文订阅 URL；尾 LF/CRLF 规整、严格双引号转义、CR/LF/NUL 残留 fail-closed（D13） |
| 服务装配 | `modules/guixcfg/system/mihomo/service.scm` | `%mihomo-data-directory`（`/var/lib/clash`）、`mihomo-config-program`（物化器，one-shot `mihomo-config-ready`）、daemon `mihomo -d /var/lib/clash -f /run/mihomo/config.yaml`（requirement：loopback/networking/config-ready）、`mihomo-activation`、clash 系统账户、`%mihomo-secrets`（ordinary secret-decl） |
| 机器状态 | `modules/guixcfg/system/mihomo/service.scm` + `modules/guixcfg/system/machine-state-persistence.scm` | `%mihomo-providers-persistence-rule`：`/persist/system/state/<backing>` → bind → `/var/lib/clash/providers` |
| Secret 链 | `modules/guixcfg/system/mihomo/secrets/mihomo-subscription.url.age` | 真实密文；age stable identity（`/persist/system/keys/age/identity`）→ ordinary 域 deploy → `/run/guixcfg-secrets-ordinary/system/mihomo-subscription.url`（0600）→ 物化器读取合成；URL 明文不进 git/store，只出现在 /run 与 root-only 日志 |

### 3.3 运行时产物与生命周期

| 产物 | 生命周期 |
|---|---|
| `/run/mihomo/config.yaml`（0700） | 物化器合成；**每次 `herd restart mihomo` 会连带重跑 one-shot 物化器重新生成**（requirement 重跑语义）——手工改它会被覆盖，热改要走 `PUT /configs`（§8） |
| `/run/guixcfg-secrets-ordinary/system/…` | secrets deploy 产物；reconfigure/重启时重建 |
| `/var/lib/clash/`（providers cache、节点选择缓存） | machine-state 持久化 |
| nscd db、smartdns 缓存 | 运行时可重建；但会缓存污染答案（§8 清法） |

### 3.4 测试锁定（tests/）

- `test-smartdns.scm` S1-S7：绑定面（无 ::1、无通配）、静态 resolv.conf、resolvconf 重定向、service graph、bootstrap 退役、**上游 DIRECT 规则存在（自举必需）**、公开配置无 secret 面；
- `test-mihomo.scm` M1-M13：合成 fail-closed 矩阵、转义、占位符唯一性、无 fake-ip/dns 段、controller loopback、**provider 无 `proxy: DIRECT`**、TUN 参数、`ipv6: false`、daemon 参数与 requirement、machine-state rule、secret decl。

---

## 4. 实测流量路径

| 流量 | 路径（TUN on） | 验证 |
|---|---|---|
| 应用 DNS | app → nscd → smartdns → **直连上游**（DIRECT 规则） | bordeaux → `185.233.100.56` 真 A + `2a0c:e300::56` 真 AAAA |
| 节点域名解析 | mihomo → 系统 DNS（smartdns）→ 直连上游 → 真答案 → 拨号节点 | 自举链条（D4）；曾因上游走节点而 SERVFAIL 死锁 |
| 应用 HTTPS | app → TUN → 规则 → 节点 | github/bordeaux/ci.guix/codeberg 全 200 |
| 订阅刷新 | mihomo → MATCH→PROXY → 节点 → api.wd-purple.com | `updatedAt` 更新、无 EOF |
| 节点健康检查 | 节点 → gstatic generate_204（lazy） | 全节点延迟可查 |
| 本地流量 | loopback/私网规则 DIRECT | 不经过任何外部 |

---

## 5. v6 语义（D6 展开）

- **解析**：AAAA 照常解析（上游直连，返回真 AAAA）；resolver 入口是 v4-literal。
- **代理**：永不——mihomo 不捕获 v6（`ipv6: false`），v6 流量不进入规则引擎、不受代理策略约束。
- **连接**：设备上行决定——VM（SLIRP 无全局 v6）v6-only 不可达、快速失败；笔记本原生 v6 直连（绕过代理 = 知情接受的泄露面）。
- **模板中的 `IP-CIDR6,fc00::/7 等 → DIRECT`**：当前不生效的防御性规则（未来若开 ipv6，本地 v6 段保证直通）。

---

## 6. 宿主侧环境约束（已知事实，非仓库责任）

2026-08-27/28 实测两条（宿主侧当时的瞬时状态；当前宿主已恢复干净）：

1. **明文 53 全局劫持**：宿主机/路由器侧残留的 clash fake-ip DNS 对一切端口 53 查询代答（`198.18.x` A + `fdfe:dcba:9876::x` AAAA），连宿主机自身的 `getent` 都被污染。
2. **直连出站不稳**：订阅 API 直连 TCP 建立后响应被 EOF 掐断。

设计立场：上游 DNS 直连是**自举必需**（D4），因此宿主侧 53 必须可信
（宿主代理全关/干净的常态）；上述两条约束若复发，直连 DNS 会被污染
（§7 矩阵第四行）。

---

## 7. 降级矩阵

| 模式 | DNS | 应用流量 | 订阅刷新 | 结论 |
|---|---|---|---|---|
| TUN on + 节点活 | ✓ 直连上游（未封域名真答案；被封域名污染） | 经节点 | 经节点 | 全功能（被封域名仅直连解析被污染） |
| TUN on + 节点死 | ✓ 直连（自举链断裂：节点域名解析仍通） | ✗ | ✗ | 换活节点恢复业务流量 |
| TUN off + 宿主干净 | ✓ 直连上游（未封域名真答案） | ✓ 直连（无代理） | ✓ 直连 | **退化为普通直连机器，正常运转** |
| TUN off + 宿主不干净 | ✗ 假 IP 污染 | 部分 EOF | ✗ | 宿主问题 |

要点：模板规则只在 TUN on 时生效；TUN off 时 mihomo 不在数据路径上，
smartdns/订阅/流量**天然直连**——所以 TUN off 不是"断网"，而是"无代理
的直连态"。未封域名全量可用；被封域名解析污染 + 连接被墙，这本来就
是代理存在的意义，任何直连设计都救不了。

---

## 8. 运维手册（VM 实测校准）

| 操作 | 方法 |
|---|---|
| 换节点 | `PUT http://127.0.0.1:9090/proxies/PROXY {"name":"…"}`；选择持久化于 `/var/lib/clash` |
| 全节点健康检查 | `GET /group/PROXY/delay?url=…&timeout=5000` |
| 手动刷订阅 | `PUT http://127.0.0.1:9090/providers/proxies/airport` |
| 热改运行配置 | 改 `/run/mihomo/config.yaml` 后 **copy 到 `/var/lib/clash/config.yaml` 再 `PUT /configs {"path":"/var/lib/clash/config.yaml"}`**（SAFE_PATHS 只允许 `-d` 目录）。**不要 `herd restart mihomo`**——它会重跑物化器，从系统世代烘焙的模板重新生成配置，覆盖手工改动 |
| 清 DNS 假 IP 缓存 | smartdns：`herd stop smartdns` → `rm /tmp/smartdns.cache`（stop 时会回写！）→ `herd start smartdns`；nscd：`herd stop nscd` → `rm /var/db/nscd/hosts` → `herd start nscd` |
| reconfigure 前置 | 先 push virelith librime 修复并更新 `channels.lock.scm` 的 virelith commit（否则 fcitx5 闭包撞 librime 构建失败）；reconfigure 后 mihomo 为"待替换"态，reboot 换上新世代 |

---

## 9. 跨文件索引

- `dns.md`：DNS ownership 分文件（决策 D1-D4、D10-D11 细节）；
- `mihomo.md`：代理分文件（D5-D9、D13-D15 细节、Phase 1 边界）；
- `secrets.md`：age secret 机制与订阅 secret 链（D12）；
- `machine-state.md`：providers cache 持久化机制（D14）。
