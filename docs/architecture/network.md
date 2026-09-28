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
│    │ DNS: getaddrinfo → nscd ─→ 127.0.0.1:53                    │
│    │ TCP: 出站流量 ─→ 默认路由 ─→ TUN (mihomo0)                 │
│    ▼                      ▼                                     │
│  NetworkManager dnsmasq          mihomo 规则引擎                  │
│  （127.0.0.1:53，专用 UID）      │ loopback/私网/ULA → DIRECT     │
│    │ upstream                    │ 其余 → MATCH → PROXY[节点]     │
│    │ (exclude-uid 绕过 TUN)      │                                │
│    ▼                             ▼                               │
│  DHCP-provided DNS         机场节点（v4-only，select 组）         │
│  （校园域 / captive portal）     │                                │
│                                  └── 节点出口：代理业务流量          │
│                                                                 │
│  DIRECT 旁路：eth0 → SLIRP/上行 → 公网（DNS 直连 + 私网）         │
└─────────────────────────────────────────────────────────────────┘
```

一句话语义：**基础解析由 NetworkManager dnsmasq 走 DHCP DNS（恒定
可达门户/校园域）；TUN on 后 mihomo 用 fake-ip + dns-hijack 接管，
DIRECT/local 回到系统 resolver，代理侧走 DoH。**

---

## 2. 设计决策逐条（决策 → 理由 → 代价）

| # | 决策 | 理由 | 代价 / 边界 |
|---|---|---|---|
| D1 | 基础 resolver 是 **NetworkManager 自带 dnsmasq**（`(dns "dnsmasq")`），监听 127.0.0.1:53 | pinned NM 原生 backend：NM 自己 exec 烘焙的 store dnsmasq 并把 libc resolver 指向它；无第二套 glue | resolver 状态归 NM；`/etc/resolv.conf` 由 NM 运行时拥有（不再 repo 静态声明） |
| D2 | `/etc/resolv.conf` 归 NetworkManager（rc-manager=resolvconf，pinned 编译期默认） | 无状态根每 boot 重建 /etc；NM 原生写 resolver 状态，repo 不覆盖 | 换 DNS 行为要走 NM 配置，而非 repo 静态文件 |
| D3 | mihomo `direct-nameserver: system`：DIRECT/local 解析经系统 resolver（dnsmasq → DHCP DNS） | 保持 captive portal / 校园域可达；单一被动数据源，无额外探测 | DIRECT 域名解析交给当前网络 DHCP DNS（可观察/伪造，知情接受） |
| D4 | TUN on 时 mihomo 接管 DNS：`dns.enable` + `enhanced-mode: fake-ip` + `dns-hijack: any:53` | 代理域名分流需要（fake-ip + sniffer）；DIRECT 仍经 `system` 回落 dnsmasq | fake-ip 会制造"解析成功但连接失败"的不可审计态——本次明确接受 |
| D5 | 代理侧 DNS 用 DoH（`nameserver` / `proxy-server-nameserver`） | 不受 GFW 污染；节点域名 bootstrap 独立 | 需要一个 IP bootstrap（`default-nameserver`）解析 DoH 域名 |
| D6 | `ipv6: false`：TUN 不捕获 v6 | 机场节点全是 v4，TUN 承载 v6 也送不到目标（实测 AAAA 目标经节点秒断）；v6 归系统原生路径 | 不承诺 v6 代理；笔记本上行有 v6 时 v6 直连绕过代理（泄露面，知情接受）；VM（SLIRP 无 v6）上 v6-only 服务不可达（快速失败） |
| D7 | 订阅刷新直连（`proxy: DIRECT`） | 刷新不依赖代理组/节点可用性——节点全挂时订阅照常更新 | 宿主直连出站不稳时刷新失败（cache-first 兜底，换节点/修宿主后经 refresh API 恢复） |
| D8 | **TUN 是唯一流量入口**：无 mixed-port、无 HTTP_PROXY 系统代理语义 | 单入口 = 可审计、无静默旁路；透明代理下应用零配置 | TUN off = 无显式回退口（干净宿主下自动退化为直连机器，见 §6） |
| D9 | 节点选择是**运行时偏好**，repo 只声明 select 组 | 节点健康随机场变化，不是 declarative 事实 | 重启/换节点后选择持久化于 `/var/lib/clash` 缓存；repo 不 pin 节点 |
| D10 | **递归切断**：dnsmasq 以专用稳定 UID（`nm-dnsmasq`）运行，mihomo `tun.exclude-uid` 排除该 UID | dnsmasq 上游 DHCP DNS 必须绕过 TUN，否则进 dns-hijack → mihomo DNS → `direct-nameserver: system` → 递归 | 依赖 sing-tun 的 UID 过滤（Linux；`auto-route` 前提）——见 dns.md「递归切断」 |
| D11 | 不引入 standalone `dnsmasq-service-type` | 单一 `:53` owner；避免与 NM dnsmasq 双实例 | — |
| D12 | 订阅密文与引用者同置（mihomo/secrets/），domain ordinary | secret taxonomy（secrets.md）；订阅不可用只影响刷新，节点仍可从本地 cache 工作 | 解密失败不阻塞登录、只降级订阅刷新 |
| D13 | 配置合成 fail-closed：两个 placeholder 各恰好一次、严格 YAML 转义、残留 CR/LF/NUL 拒绝 | 订阅 URL 是唯一 secret 注入点，坏输入必须失败而非产出可运行错配置 | 物化失败 → mihomo 起不来（显式失败优于静默错） |
| D14 | machine-state 持久化整个 mihomo 数据目录（`/var/lib/clash`：providers cache + cache.db 选中节点/组状态，bind-directory，root-owned） | 订阅拉取结果与节点选择都是 machine-owned mutable state，重启后都要保留 | 单目录 bind，不扩权 |
| D15 | controller loopback-only、无 secret | 控制面只给本机运维，不进网络面 | 需要本机 shell 才能换节点/刷新 |
| D16 | 删除 SmartDNS 控制平面（service / DHCP fallback / openresolv 重定向 / NM dispatcher / 固定上游 223.5.5.5、119.29.29.29） | DNS 所有权收敛到 NM dnsmasq（基础）+ mihomo（TUN），不再维护自定义 resolver 状态机 | 固定公共 DNS 仅作为 mihomo DoH bootstrap 保留（D5），不再是系统 resolver 上游 |

---

## 3. 具体实现方式

### 3.1 DNS 层

| 组件 | 位置 | 实现要点 |
|---|---|---|
| NM dns backend | `modules/guixcfg/hosts/vm.scm`、`modules/guixcfg/hosts/lenovo-legion-y7000p.scm` | `(dns "dnsmasq")` + `(dnsmasq-configuration-files (nm-dnsmasq-dnsmasq-configuration-files))` |
| 专用账号/配置 | `modules/guixcfg/system/dns/nm-dnsmasq.scm` | 系统账号 `nm-dnsmasq`（显式 UID/GID 985）、`/etc/NetworkManager/dnsmasq.d/00-nm-dnsmasq-user.conf`（`user=nm-dnsmasq`）、`account-service-type` 贡献 |
| `direct-nameserver` | `modules/guixcfg/system/mihomo/template.yaml` | `- system`（经 /etc/resolv.conf → dnsmasq → DHCP DNS） |
| 递归切断 | 同上（`tun.exclude-uid`）+ 上表账号 | 模板 `@@MIHOMO_NM_DNSMASQ_UID@@` 由 `modules/guixcfg/system/mihomo/config.scm` 注入同一 UID |

### 3.2 代理层

| 组件 | 位置 | 实现要点 |
|---|---|---|
| 模板 | `modules/guixcfg/system/mihomo/template.yaml` | TUN（mixed stack、auto-route/auto-redirect/auto-detect-interface、`dns-hijack: any:53` + `tcp://any:53`、`exclude-uid`）、`ipv6: false`；`dns` 段：fake-ip + `direct-nameserver: system` + DoH `nameserver`/`proxy-server-nameserver` + IP `default-nameserver`；`sniffer`；规则 = 私网/loopback/ULA DIRECT + `MATCH,PROXY`；provider：原生 http、`interval: 3600`、lazy health-check、`proxy: DIRECT`（D7）；占位符 `@@MIHOMO_SUBSCRIPTION_URL@@` 与 `@@MIHOMO_NM_DNSMASQ_UID@@` 各恰好一次 |
| 配置合成 | `modules/guixcfg/system/mihomo/config.scm` | `compose-mihomo-config`：模板 + `/run` 明文订阅 URL + UID；尾 LF/CRLF 规整、严格双引号转义、CR/LF/NUL 残留、placeholder 唯一性 fail-closed（D13） |
| 服务装配 | `modules/guixcfg/system/mihomo/service.scm` | `%mihomo-data-directory`（`/var/lib/clash`）、`mihomo-config-program`（物化器，one-shot `mihomo-config-ready`）、daemon `mihomo -d /var/lib/clash -f /run/mihomo/config.yaml`（requirement：loopback/networking/config-ready）、`mihomo-activation`、clash 系统账户、`%mihomo-secrets`（ordinary secret-decl） |
| 机器状态 | `modules/guixcfg/system/mihomo/service.scm` + `modules/guixcfg/system/machine-state-persistence.scm` | `%mihomo-data-persistence-rule`：`/persist/system/state/mihomo/clash` → bind → `/var/lib/clash`（整个 `-d`） |
| Secret 链 | `modules/guixcfg/system/mihomo/secrets/mihomo-subscription.url.age` | 真实密文；age stable identity（`/persist/system/keys/age/identity`）→ ordinary 域 deploy → `/run/guixcfg-secrets-ordinary/system/mihomo-subscription.url`（0600）→ 物化器读取合成；URL 明文不进 git/store |

### 3.3 运行时产物与生命周期

| 产物 | 生命周期 |
|---|---|
| `/run/mihomo/config.yaml`（0700） | 物化器合成；**每次 `herd restart mihomo` 会连带重跑 one-shot 物化器重新生成**（requirement 重跑语义）——手工改它会被覆盖，热改要走 `PUT /configs`（§8） |
| `/run/guixcfg-secrets-ordinary/system/…` | secrets deploy 产物；reconfigure/重启时重建 |
| `/var/lib/clash/`（providers cache、节点选择缓存） | machine-state 持久化 |
| `/etc/resolv.conf` | NetworkManager 经 openresolv 运行时写入；ephemeral root 中每次 boot 重建 |
| nscd db | 运行时可重建；会缓存污染答案（§8 清法） |

### 3.4 测试锁定（tests/）

- `tests/test-nm-dnsmasq.scm` N1-N7：NM `dns=dnsmasq`、专用账号配置内容、账号/组显式稳定 UID/GID、无 SmartDNS 残留、无 standalone dnsmasq、host 装配引用、mihomo 组合配置的 `exclude-uid`/`direct-nameserver`/fake-ip 一致；
- `tests/test-mihomo.scm` M1-M14：合成 fail-closed 矩阵、转义、两个 placeholder 唯一性、fake-ip/dns-hijack 存在、`direct-nameserver: system`、UID 占位符替换、controller loopback、**provider `proxy: DIRECT`**、TUN 参数、`ipv6: false`、daemon 参数与 requirement（无 smartdns）、machine-state rule、secret decl。

---

## 4. 实测流量路径

| 流量 | 路径（TUN on） | 验证 |
|---|---|---|
| 应用 DNS | app → nscd → dnsmasq(127.0.0.1:53) → DHCP DNS | 校园域 / 公网域名均可解析 |
| DIRECT 解析 | mihomo → `direct-nameserver: system` → dnsmasq → DHCP DNS | 经 /etc/resolv.conf（loopback，不进 TUN） |
| 代理侧解析 | mihomo → DoH（`nameserver`/`proxy-server-nameserver`） | DoH 域名经 `default-nameserver` IP bootstrap |
| dnsmasq 上游 | dnsmasq（UID 985）→ DHCP DNS，**绕过 TUN** | sing-tun `meta skuid` 排除（D10） |
| 应用 HTTPS | app → TUN → 规则 → 节点 | github/bordeaux/ci.guix/codeberg 全 200 |
| 订阅刷新 | mihomo → DIRECT（宿主直连）→ 订阅端点 | `updatedAt` 更新、无 EOF |
| 节点健康检查 | 节点 → gstatic generate_204（lazy） | 全节点延迟可查 |
| 本地流量 | loopback/私网规则 DIRECT | 不经过任何外部 |

---

## 5. v6 语义（D6 展开）

- **解析**：AAAA 照常解析；resolver 入口是 v4 loopback（dnsmasq 监听 127.0.0.1）。
- **代理**：永不——mihomo 不捕获 v6（`ipv6: false`），v6 流量不进入规则引擎、不受代理策略约束。
- **连接**：设备上行决定——VM（SLIRP 无全局 v6）v6-only 不可达、快速失败；笔记本原生 v6 直连（绕过代理 = 知情接受的泄露面）。
- **模板中的 `IP-CIDR6,fc00::/7 等 → DIRECT`**：当前不生效的防御性规则。

---

## 6. 降级矩阵

| 模式 | DNS | 应用流量 | 订阅刷新 | 结论 |
|---|---|---|---|---|
| TUN on + 节点活 | ✓ dnsmasq→DHCP；DIRECT 经 system；代理经 DoH | 经节点 | ✓ 直连（proxy: DIRECT） | 全功能 |
| TUN on + 节点死 | ✓ dnsmasq→DHCP（校园域/门户仍通） | ✗ | ✓ 直连（刷新不依赖节点） | 换活节点恢复业务流量 |
| TUN off + 宿主干净 | ✓ dnsmasq→DHCP | ✓ 直连（无代理） | ✓ 直连 | **退化为普通直连机器；captive portal 直接经 DHCP DNS 完成认证** |
| TUN off + 宿主不干净 | ✗ 假 IP 污染 | 部分 EOF | ✗ | 宿主问题 |

要点：TUN off 时 mihomo 不在数据路径上，NetworkManager dnsmasq + 直连
流量天然工作——TUN off 不是"断网"，而是"无代理的直连态"。

---

## 8. 运维手册（VM 实测校准）

| 操作 | 方法 |
|---|---|
| 换节点 | `PUT http://127.0.0.1:9090/proxies/PROXY {"name":"…"}`；选择持久化于 `/var/lib/clash` |
| 全节点健康检查 | `GET /group/PROXY/delay?url=…&timeout=5000` |
| 手动刷订阅 | `PUT http://127.0.0.1:9090/providers/proxies/airport` |
| 热改运行配置 | 改 `/run/mihomo/config.yaml` 后 **copy 到 `/var/lib/clash/config.yaml` 再 `PUT /configs {"path":"/var/lib/clash/config.yaml"}`**（SAFE_PATHS 只允许 `-d` 目录）。**不要 `herd restart mihomo`**——它会重跑物化器覆盖手工改动 |
| 清 DNS 假 IP 缓存 | `herd restart mihomo`（fake-ip 缓存随进程重建）；nscd：`herd stop nscd` → `rm /var/db/nscd/hosts` → `herd start nscd` |
| 查 DNS owner | `ss -lntup | grep ':53'`（应只见 NM 的 dnsmasq 于 127.0.0.1:53）；`ps -o user,pid,args -C dnsmasq`（用户应为 `nm-dnsmasq`） |

---

## 9. 跨文件索引

- `dns.md`：DNS ownership 分文件（目标链、递归切断、D1-D3/D10/D16 细节）；
- `mihomo.md`：代理分文件（D4-D9、D13-D15 细节）；
- `secrets.md`：age secret 机制与订阅 secret 链（D12）；
- `machine-state.md`：mihomo 数据目录持久化机制（D14）。
