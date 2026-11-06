# System networking architecture（网络全链路）

本文件是横切总结；DNS 细节见 `dns.md`，Mihomo 细节见
`mihomo.md`，订阅 secret 链见 `secrets.md`。

## 1. 全景图

```text
App
  │ DNS: /etc/resolv.conf 127.0.0.1
  ▼
SmartDNS（127.0.0.1:53，UID 984）
  ├─ fixed：AliDNS IP DoH
  └─ dhcp ：NetworkManager dnsmasq（127.0.0.1:15353，UID 985）
                └─ 当前 DHCP DNS

App TCP/UDP
  ↓
TUN（mihomo0）
  ↓
Mihomo 规则引擎（sniffer + cn-ip + domain rule sets）
  ├─ DIRECT → 宿主上行
  └─ PROXY  → 机场节点
```

一句话：**SmartDNS 是唯一应用 resolver；Mihomo 只做 TUN/规则/代理，
不再拥有 DNS。DNS 模式由用户显式选择，fixed=DoH only，
dhcp=DHCP DNS only，不跨模式 fallback。**

---

## 2. 设计决策

| # | 决策 | 理由 | 代价 / 边界 |
|---|---|---|---|
| D1 | 应用 resolver 是 SmartDNS（127.0.0.1:53）；NM dnsmasq 退到 15353 | DNS 与 Mihomo 解耦；Mihomo 崩溃不导致断网 | 多一个独立 resolver 进程 |
| D2 | `/etc/resolv.conf` 仍归 NM（openresolv），写 127.0.0.1 | ephemeral root 由 NM 原生管理；不新增 resolv.conf owner | NM 不知道 53 现在是 SmartDNS，但语义不变 |
| D3 | DNS 模式由用户显式选择，持久化在 `/var/lib/guixcfg-dns/mode` | 不做连接类型自动推断；选择即事实 | fixed 选在 DHCP 网络时本地名字不可用 |
| D4 | fixed 只允许 AliDNS IP DoH；dhcp 只允许 NM dnsmasq | 两模式严格二选一；固定模式不泄漏 DHCP DNS | fixed 模式无 DHCP fallback |
| D5 | 不维护本地域名列表、无 `nameserver-policy`、无 fallback | 避免 SmartDNS 旧式复杂状态机；行为可预测 | fixed 模式本地名字不解析 |
| D6 | `ipv6: false`：TUN 不捕获 v6 | 机场节点 v4-only；v6 经节点不可达 | v6 直连绕过 Mihomo |
| D7 | 订阅刷新直连（provider `proxy: DIRECT`） | 节点全挂时订阅仍可刷新 | 宿主直连不稳时刷新失败 |
| D8 | TUN 是唯一流量入口；无 mixed-port 系统代理 | 单入口可审计 | TUN off = 无代理直连态 |
| D9 | 节点选择是运行时偏好，持久化于 `/var/lib/clash` | 节点健康随网络变化 | repo 不 pin 节点 |
| D10 | SmartDNS 与 dnsmasq 的上游以 UID 984/985 排除出 TUN | 切断 DNS → TUN 递归；DoH 不依赖 Mihomo | 依赖 sing-tun `exclude-uid` |
| D11 | 没有自定义 DNS CLI；面板写 mode 文件，root applier 执行 | 不引入 setuid/sudo/socket；只有 mode 一个可写输入 | 面板依赖文件权限 |
| D12 | 订阅密文与引用者同置，ordinary domain | secret taxonomy | 解密失败不阻塞登录 |
| D13 | 配置合成 fail-closed；providers/groups/两个 UID 占位符各一次 | 坏输入必须失败 | materializer 失败 → Mihomo 起不来 |
| D14 | `/var/lib/clash` 整体 machine-state 持久化 | provider cache + selected node 都需跨 boot | 单目录 bind |
| D15 | controller loopback-only、无 secret | 单用户本机控制面 | 需要本机 shell |

---

## 3. DNS 控制面

```text
Noctalia Network Layer DNS card
  ↓ 直接写 /var/lib/guixcfg-dns/mode（fixed|dhcp）
root guixcfg-dns-mode applier
  ├─ 校验 fixed/dhcp
  ├─ 原子切换 /run/guixcfg-dns/smartdns.conf
  ├─ herd restart smartdns
  └─ 写 /run/guixcfg-dns/applied、status、smartdns-status
```

- 无 NM dispatcher、无自动连接分类、无自定义 CLI。
- 模式持久化：`/persist/system/state/guixcfg-dns` bind →
  `/var/lib/guixcfg-dns`。
- 文件缺失默认 fixed；非法值忽略。
- 模式切换不自动回退。

### 组件

| 组件 | 位置 | 职责 |
|---|---|---|
| SmartDNS | `modules/guixcfg/system/dns/smartdns.scm` | resolver、两份静态配置、mode applier、账号/UID |
| NM dnsmasq | `modules/guixcfg/system/dns/nm-dnsmasq.scm` | DHCP DNS source，15353，UID 985 |
| DNS mode state | `/var/lib/guixcfg-dns/mode` | 唯一 desired state |
|  Route/applied/status/health | `/run/guixcfg-dns/` | 运行时反馈 |
| `/etc/resolv.conf` | NetworkManager | `nameserver 127.0.0.1` |
| Mihomo | `modules/guixcfg/system/mihomo` | TUN/规则/代理；DNS 关闭 |

---

## 4. 代理层

| 组件 | 位置 | 要点 |
|---|---|---|
| 模板 | `mihomo/template.yaml` | 无 `dns` 段；TUN mixed stack、auto-route/redirect、exclude UID 984/985；sniffer；规则 |
| 配置合成 | `mihomo/config.scm` | 四个占位符各一次；两个 UID 同时注入；严格转义/fail-closed |
| 服务 | `mihomo/service.scm` | materializer one-shot + daemon；-d `/var/lib/clash`、-f `/run/mihomo/config.yaml` |
| 持久化 | `%mihomo-data-persistence-rule` | `/persist/system/state/mihomo/clash` → `/var/lib/clash` |
| Secret | `mihomo/secrets/*.age` + sources | 每源一个 age；ordinary deploy |

### 流量

| 流量 | 路径 |
|---|---|
| 应用 DNS | app → 127.0.0.1:53 → SmartDNS |
| fixed DNS | SmartDNS → AliDNS IP DoH |
| dhcp DNS | SmartDNS → dnsmasq:15353 → DHCP DNS |
| 应用 TCP/UDP | TUN → 规则 → DIRECT/PROXY |
| DIRECT 解析 | SmartDNS；不需要 Mihomo DNS |
| 代理节点域名 | SmartDNS（Noctalia/host resolver） |
| 订阅刷新 | Mihomo DIRECT |
| loopback/私网 | 规则 DIRECT |

---

## 5. 失败矩阵

| 故障 | DNS | 业务流量 |
|---|---|---|
| Mihomo 崩溃 | SmartDNS 继续工作 | TUN 消失，直连/失败；DNS 不受影响 |
| SmartDNS 崩溃 | 失败；Shepherd respawn | 已建立连接不受影响；新解析失败 |
| fixed DoH 不可达 | 失败；不回退 DHCP | 新域名连接失败 |
| dhcp DNS 不可达 | 失败；不回退 DoH | 新域名连接失败 |
| mode 文件非法 | 保持已应用模式 | 无额外影响 |
| mode 切换失败 | applied 不更新，status=error | 旧模式继续 |
| TUN on | SmartDNS 独立 | 业务经代理；DNS 走 UID 排除 |
| TUN off | SmartDNS 独立 | 业务直连 |

---

## 6. 运维

| 操作 | 方法 |
|---|---|
| 切换 DNS 模式 | Noctalia Network Layer → DNS 卡片 |
| 查看期望/已应用模式 | `cat /var/lib/guixcfg-dns/mode /run/guixcfg-dns/applied` |
| 查看切换错误 | `cat /run/guixcfg-dns/status /run/guixcfg-dns/smartdns-status` |
| 查 DNS owner | `ss -lntup | grep -E ':53|:15353'`（SmartDNS / dnsmasq） |
| 查 SmartDNS 日志 | `/var/log/smartdns.log` |
| 查 mode applier 日志 | `/var/log/guixcfg-dns-mode.log` |
| 换节点 | `PUT /proxies/PROXY`；持久化在 `/var/lib/clash` |
| 刷订阅 | `PUT /providers/proxies/<name>` |
| 清 DNS 缓存 | restart smartdns / restart mihomo（视缓存 owner） |

---

## 7. 测试

- `tests/test-smartdns.scm`：配置互斥、UID、mode persistence、
  Shepherd 图、mode applier 真实 `--check`。
- `tests/test-nm-dnsmasq.scm`：NM dns=dnsmasq、15353、UID 985、
  SmartDNS 服务存在、无 standalone dnsmasq。
- `tests/test-mihomo.scm`：模板无 DNS/hijack、四个占位符、
  两个 UID 的 materializer 替换、服务图、machine-state。
- `tests/test-machine-state-persistence.scm`：通用机制。

测试不依赖公网实际 DNS 或 DHCP 地址，只验证机制与 ownership。
