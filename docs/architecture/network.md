# System networking architecture（网络全链路）

本文件是网络架构的**横切总结**：把 DNS ownership（见 `dns.md`）、
Mihomo 透明代理（见 `mihomo.md`）、订阅 secret 链（见 `secrets.md`）
与实测得到的宿主侧环境约束串成一张完整图。组件细节以各分文件为准，
本文件只讲全链路的**设计决策与实现方式**。

---

## 1. 全景图

```
┌─ 设备（VM / 笔记本，同一 repo 语义）─────────────────────────────┐
│                                                                 │
│  App（curl/guix/浏览器）                                        │
│    │ DNS: getaddrinfo → nscd ─→ 127.0.0.1:53 (mihomo)            │
│    │ TCP: 出站流量 ─→ 默认路由 ─→ TUN (mihomo0)                 │
│    ▼                      ▼                                     │
│  mihomo DNS                mihomo 规则引擎                       │
│  （127.0.0.1:53）          │ loopback/私网/ULA → DIRECT          │
│    ├─ 固定 AliDNS IP DoH  │ 其余 → MATCH → PROXY[节点]          │
│    └─ fallback :15353      │                                     │
│         ↓                  ▼                                     │
│  NM dnsmasq             机场节点（v4-only，select 组）            │
│  （127.0.0.1:15353）       │                                     │
│    ↓ upstream             └── 节点出口：代理业务流量              │
│  DHCP-provided DNS（校园域 / captive portal）                     │
│                                                                 │
│  DIRECT 旁路：eth0 → SLIRP/上行 → 公网（DNS 直连 + 私网）         │
└─────────────────────────────────────────────────────────────────┘
```

一句话语义：**mihomo 是应用 DNS 的唯一入口，固定 AliDNS IP DoH
（223.5.5.5 / 223.6.6.6）优先；连接失败、NXDOMAIN 或 LAN IP
时回退到 NetworkManager dnsmasq 的当前 DHCP DNS；两边都失败则正常
失败。** TUN 只决定业务流量是否进入 mihomo，不再切换 DNS 所有权。

---

## 2. 设计决策逐条（决策 → 理由 → 代价）

| # | 决策 | 理由 | 代价 / 边界 |
|---|---|---|---|
| D1 | 应用 resolver 是 **mihomo DNS**，监听 127.0.0.1:53；NetworkManager dnsmasq 退到 127.0.0.1:15353 | mihomo 的 `fallback` 需要独立 DHCP 上游；:53 只能有一个 owner。NM 仍拥有 dnsmasq/当前 DHCP DNS | resolver 入口归 mihomo；dnsmasq 端口不是 53，`ss` 检查要同时看两个端口 |
| D2 | `/etc/resolv.conf` 归 NetworkManager（rc-manager=resolvconf，pinned 编译期默认） | 无状态根每 boot 重建 /etc；NM 原生写 resolver 状态，repo 不覆盖 | NM 写 `127.0.0.1`（现在指向 mihomo:53） |
| D3 | mihomo `fallback` / `direct-nameserver` 指向 `127.0.0.1:15353`（NM dnsmasq → 当前 DHCP DNS） | 保持 captive portal / 校园域可达；不把 DHCP 地址写死，也没有 `system` 回环 | DHCP 域名解析交给当前网络 DNS（可观察/伪造，知情接受） |
| D4 | DNS 用 `redir-host`，不用 fake-ip；`fallback-lazy-query: true` + `fallback-filter.geoip-code: LAN` | 真实解析才能让 NXDOMAIN/空答案/失败触发 fallback；LAN 是地址分类而不是域名列表 | 无 fake-ip 的远端解析；内网名字会先被公共 AliDNS 看到（NXDOMAIN 后回退） |
| D5 | 固定上游用阿里云 AliDNS IP DoH（`https://223.5.5.5/dns-query` / `https://223.6.6.6/dns-query`）；节点域名用独立 `proxy-server-nameserver` | 固定 IP、TLS 证书含 IP，避免 UDP 53 被 TUN hijack 回环，也不需要域名 bootstrap | DoH 直连、不经代理；代理不可用不影响 DNS |
| D6 | `ipv6: false`：TUN 不捕获 v6 | 机场节点全是 v4，TUN 承载 v6 也送不到目标（实测 AAAA 目标经节点秒断）；v6 归系统原生路径 | 不承诺 v6 代理；笔记本上行有 v6 时 v6 直连绕过代理（泄露面，知情接受）；VM（SLIRP 无 v6）上 v6-only 服务不可达（快速失败） |
| D7 | 订阅刷新直连（`proxy: DIRECT`） | 刷新不依赖代理组/节点可用性——节点全挂时订阅照常更新 | 宿主直连出站不稳时刷新失败（cache-first 兜底，换节点/修宿主后经 refresh API 恢复） |
| D8 | **TUN 是唯一流量入口**：无 mixed-port、无 HTTP_PROXY 系统代理语义 | 单入口 = 可审计、无静默旁路；透明代理下应用零配置 | TUN off = 无显式回退口（干净宿主下自动退化为直连机器，见 §6） |
| D9 | 节点选择是**运行时偏好**，repo 只声明 select 组 | 节点健康随机场变化，不是 declarative 事实 | 重启/换节点后选择持久化于 `/var/lib/clash` 缓存；repo 不 pin 节点 |
| D10 | **递归切断**：dnsmasq 以专用稳定 UID（`nm-dnsmasq`）运行，mihomo `tun.exclude-uid` 排除该 UID | dnsmasq 上游 DHCP DNS 必须绕过 TUN，否则进 dns-hijack → mihomo DNS，形成递归 | 依赖 sing-tun 的 UID 过滤（Linux；`auto-route` 前提）——见 dns.md「递归切断」 |
| D11 | `:53` 归 mihomo，`:15353` 归 NM dnsmasq；不引入 standalone resolver | 单一应用 DNS 入口 + 独立 DHCP fallback；避免 `system` 指回 mihomo 的回环 | 两个端口都要在运维检查中覆盖 |
| D12 | 订阅密文与引用者同置（mihomo/secrets/），domain ordinary | secret taxonomy（secrets.md）；订阅不可用只影响刷新，节点仍可从本地 cache 工作 | 解密失败不阻塞登录、只降级订阅刷新 |
| D13 | 配置合成 fail-closed：providers/groups/UID 三个 placeholder 各恰好一次、manifest 行校验、严格 YAML 转义、NUL/CR 拒绝 | manifest 是唯一 secret 注入点，坏输入/坏源名/重复源必须失败而非产出可运行错配置 | 物化失败 → mihomo 起不来（显式失败优于静默错） |
| D14 | machine-state 持久化整个 mihomo 数据目录（`/var/lib/clash`：providers cache + cache.db 选中节点/组状态，bind-directory，root-owned） | 订阅拉取结果与节点选择都是 machine-owned mutable state，重启后都要保留 | 单目录 bind，不扩权 |
| D15 | controller loopback-only、无 secret | 控制面只给本机运维，不进网络面 | 需要本机 shell 才能换节点/刷新 |
| D16 | SmartDNS 保持退役；DNS 收敛为 mihomo（:53，AliDNS IP DoH + fallback）+ NM dnsmasq（:15353，DHCP DNS） | 不再维护自定义 resolver 状态机；不需要域名列表 | 所有 DNS 先走 AliDNS DoH；内网名字有首查延迟/泄漏；mihomo 成为 DNS 单点 |

---

## 3. 具体实现方式

### 3.1 DNS 层

| 组件 | 位置 | 实现要点 |
|---|---|---|
| NM dns backend | `modules/guixcfg/hosts/vm.scm`、`modules/guixcfg/hosts/lenovo-legion-y7000p.scm` | `(dns "dnsmasq")` + `(dnsmasq-configuration-files (nm-dnsmasq-dnsmasq-configuration-files))` |
| 专用账号/配置 | `modules/guixcfg/system/dns/nm-dnsmasq.scm` | 系统账号 `nm-dnsmasq`（显式 UID/GID 985）、`00-nm-dnsmasq-user.conf`（`user=`）、`10-listen-port.conf`（`port=15353`）、`account-service-type` 贡献 |
| 应用 DNS 入口 | `modules/guixcfg/system/mihomo/template.yaml` | `listen: 127.0.0.1:53`；`redir-host`；AliDNS IP DoH `https://223.5.5.5/dns-query`/`https://223.6.6.6/dns-query`；`fallback`/`direct-nameserver` = `127.0.0.1:15353`；`fallback-lazy-query: true`；`fallback-filter.geoip-code: LAN` |
| 递归切断 | 同上（`tun.exclude-uid`）+ 上表账号 | 模板 `@@MIHOMO_NM_DNSMASQ_UID@@` 由 `modules/guixcfg/system/mihomo/config.scm` 注入同一 UID |

### 3.2 代理层

| 组件 | 位置 | 实现要点 |
|---|---|---|
| 模板 | `modules/guixcfg/system/mihomo/template.yaml` | TUN（mixed stack、auto-route/auto-redirect/auto-detect-interface、`dns-hijack: any:53` + `tcp://any:53`、`exclude-uid`）、`ipv6: false`；`dns` 段：`listen: 127.0.0.1:53`、`redir-host`、AliDNS IP DoH `nameserver`、`fallback`/`direct-nameserver` = `127.0.0.1:15353`、`fallback-lazy-query`、`fallback-filter.geoip-code: LAN`、`proxy-server-nameserver`、IP `default-nameserver`；`sniffer`；规则 = 私网/loopback/ULA DIRECT + Loyalsoldier proxy/direct 规则集 + `MATCH,PROXY`；provider/groups 由 manifest 生成（`@@MIHOMO_PROXY_PROVIDERS@@` / `@@MIHOMO_PROXY_GROUPS@@`），UID 为 `@@MIHOMO_NM_DNSMASQ_UID@@`，三者各恰好一次 |
| 配置合成 | `modules/guixcfg/system/mihomo/config.scm` | `compose-mihomo-config`：模板 + `/run` 明文 subscription manifest + UID；解析 `name=url-or-file-path`，生成每源 provider 与 `SRC-*` select 组、顶层 `PROXY`；尾 LF/CRLF 规整、严格双引号转义、NUL/CR 拒绝、placeholder 唯一性 fail-closed（D13） |
| 服务装配 | `modules/guixcfg/system/mihomo/service.scm` | `%mihomo-data-directory`（`/var/lib/clash`）、`mihomo-config-program`（物化器，one-shot `mihomo-config-ready`）、daemon `mihomo -d /var/lib/clash -f /run/mihomo/config.yaml`（requirement：loopback/networking/config-ready）、`mihomo-activation`、clash 系统账户、`%mihomo-secrets`（ordinary secret-decl） |
| 机器状态 | `modules/guixcfg/system/mihomo/service.scm` + `modules/guixcfg/system/machine-state-persistence.scm` | `%mihomo-data-persistence-rule`：`/persist/system/state/mihomo/clash` → bind → `/var/lib/clash`（整个 `-d`） |
| Secret 链 | `modules/guixcfg/system/mihomo/secrets/mihomo-subscription.url.age` | 真实密文；age stable identity（`/persist/system/keys/age/identity`）→ ordinary 域 deploy → `/run/guixcfg-secrets-ordinary/system/mihomo-subscription.url`（0600）→ 物化器读取并生成多源配置；manifest 明文不进 git/store |
| 文件订阅源 | `/var/lib/clash/subscriptions/` | activation 创建 0700 目录；manifest 行 `name=/var/lib/clash/subscriptions/file.yaml`；文件必须是 provider YAML |

### 3.3 运行时产物与生命周期

| 产物 | 生命周期 |
|---|---|
| `/run/mihomo/config.yaml`（0700） | 物化器合成；**每次 `herd restart mihomo` 会连带重跑 one-shot 物化器重新生成**（requirement 重跑语义）——手工改它会被覆盖，热改要走 `PUT /configs`（§8） |
| `/run/guixcfg-secrets-ordinary/system/…` | secrets deploy 产物；reconfigure/重启时重建 |
| `/var/lib/clash/`（providers cache、节点选择缓存） | machine-state 持久化 |
| `/etc/resolv.conf` | NetworkManager 经 openresolv 运行时写入；ephemeral root 中每次 boot 重建 |
| nscd db | 运行时可重建；会缓存污染答案（§8 清法） |

### 3.4 测试锁定（tests/）

- `tests/test-nm-dnsmasq.scm` N1-N7：NM `dns=dnsmasq`、专用账号配置内容 + 15353 端口、账号/组显式稳定 UID/GID、无 SmartDNS 残留、无 standalone dnsmasq、host 装配引用、mihomo 组合配置的 `exclude-uid`/`:53` 监听/`redir-host`/AliDNS/fallback 一致；
- `tests/test-mihomo.scm` M1-M16：合成 fail-closed 矩阵、转义、三个 placeholder 唯一性、多源/文件源/重复名/非法名、`:53`/redir-host/dns-hijack 存在、AliDNS/fallback :15353/LAN 过滤、UID 占位符替换、controller loopback、**provider `proxy: DIRECT`**、TUN 参数、`ipv6: false`、daemon 参数与 requirement（无 smartdns）、machine-state rule、secret decl。

---

## 4. 实测流量路径

| 流量 | 路径（TUN on/off 相同） | 验证 |
|---|---|---|
| 应用 DNS（固定优先） | app → nscd → mihomo(127.0.0.1:53) → AliDNS IP DoH 223.5.5.5/223.6.6.6 | 公网域名解析；mihomo 日志有上游记录 |
| 应用 DNS（回退） | mihomo → NXDOMAIN/失败/私网 IP → dnsmasq(127.0.0.1:15353) → DHCP DNS | 校园域 / captive portal / 内网 FQDN |
| 应用 DNS（双失败） | mihomo 返回 SERVFAIL/NXDOMAIN | 不再无限回退；应用看到正常失败 |
| DIRECT 解析 | mihomo → `direct-nameserver: 127.0.0.1:15353` → dnsmasq → DHCP DNS | loopback，不进 TUN |
| 代理节点解析 | mihomo → `proxy-server-nameserver` DoH | DoH 域名经 `default-nameserver` IP bootstrap |
| dnsmasq 上游 | dnsmasq（UID 985）→ DHCP DNS，**绕过 TUN** | sing-tun `meta skuid` 排除（D10） |
| 应用 HTTPS | app → TUN → 规则 → 节点 | github/bordeaux/ci.guix/codeberg 全 200 |
| 订阅刷新 | mihomo → DIRECT（宿主直连）→ 订阅端点 | `updatedAt` 更新、无 EOF |
| 节点健康检查 | 节点 → gstatic generate_204（lazy） | 全节点延迟可查 |
| 本地流量 | loopback/私网规则 DIRECT | 不经过任何外部 |

---

## 5. v6 语义（D6 展开）

- **解析**：AAAA 照常解析；resolver 入口是 v4 loopback（mihomo DNS 监听 127.0.0.1:53）。
- **代理**：永不——mihomo 不捕获 v6（`ipv6: false`），v6 流量不进入规则引擎、不受代理策略约束。
- **连接**：设备上行决定——VM（SLIRP 无全局 v6）v6-only 不可达、快速失败；笔记本原生 v6 直连（绕过代理 = 知情接受的泄露面）。
- **模板中的 `IP-CIDR6,fc00::/7 等 → DIRECT`**：当前不生效的防御性规则。

---

## 6. 降级矩阵

| 模式 | DNS | 应用流量 | 订阅刷新 | 结论 |
|---|---|---|---|---|
| TUN on + 节点活 | ✓ AliDNS IP DoH 优先；失败回退 DHCP | 经节点 | ✓ 直连（proxy: DIRECT） | 全功能 |
| TUN on + 节点死 | ✓ AliDNS 失败 → fallback dnsmasq→DHCP；校园域/门户仍通 | ✗ | ✓ 直连（刷新不依赖节点） | 换活节点恢复业务流量 |
| TUN off + 宿主干净 | ✓ 仍先 AliDNS；不可用时回退 DHCP | ✓ 直连（无代理） | ✓ 直连 | 退化为普通直连机器；LAN 靠 fallback |
| 两边 DNS 都失败 | ✗ mihomo 返回 SERVFAIL/NXDOMAIN | 部分失败 | — | 正常失败，不无限回退 |

要点：TUN 只切业务流量，不再切 DNS；TUN off 不是“断网”，而是
“无代理的直连态”，DNS 仍按固定 AliDNS 优先 + DHCP fallback 工作。

---

## 8. 运维手册（VM 实测校准）

| 操作 | 方法 |
|---|---|
| 换节点 | `PUT http://127.0.0.1:9090/proxies/PROXY {"name":"…"}`；选择持久化于 `/var/lib/clash` |
| 全节点健康检查 | `GET /group/PROXY/delay?url=…&timeout=5000` |
| 手动刷订阅 | `PUT http://127.0.0.1:9090/providers/proxies/<name>`（文件源跳过） |
| 热改运行配置 | 改 `/run/mihomo/config.yaml` 后 **copy 到 `/var/lib/clash/config.yaml` 再 `PUT /configs {"path":"/var/lib/clash/config.yaml"}`**（SAFE_PATHS 只允许 `-d` 目录）。**不要 `herd restart mihomo`**——它会重跑物化器覆盖手工改动 |
| 清 DNS 缓存 | `herd restart mihomo`（清 mihomo 缓存）；nscd：`herd stop nscd` → `rm /var/db/nscd/hosts` → `herd start nscd` |
| 查 DNS owner | `ss -lntup | grep -E ':53|:15353'`：mihomo 应在 127.0.0.1:53，dnsmasq 应在 127.0.0.1:15353；`ps -o user,pid,args -C dnsmasq`（用户应为 `nm-dnsmasq`） |

---

## 9. 跨文件索引

- `dns.md`：DNS ownership 分文件（目标链、递归切断、D1-D3/D10/D16 细节）；
- `mihomo.md`：代理分文件（D4-D9、D13-D15 细节）；
- `secrets.md`：age secret 机制与订阅 secret 链（D12）；
- `machine-state.md`：mihomo 数据目录持久化机制（D14）。
