# Machine-owned Mutable System State

第四种 persistence ownership（docs/architecture/persistence.md）：

```text
/persist/data-home       user-owned data
/persist/data-app        application-owned mutable user state → HOME bind
/persist/data-nobackup   bulk/reacquirable direct-access data
/persist/system          machine-owned identity/state
```

本文件定义 `/persist/system` 内 **mutable daemon/system state** 的
架构位置与 generic projection 机制。

## 问题

无状态 root（ephemeral root generation）下，daemon/GUI 运行期写入
标准 `/etc`、`/var/lib` 等位置的 mutable state 会随 root 重建丢失：

```text
GUI connect Wi-Fi
    ↓
NetworkManager 写 profile/password 到 /etc/NetworkManager/...
    ↓
下次 ephemeral boot → 丢失 → 需要重新连接
```

canonical state 必须留在 `/persist/system`，标准位置只是
projection。

## 机制

`modules/guixcfg/system/machine-state-persistence.scm`（generic
executor，不知道具体 daemon）：

```text
/persist/system/state/<backing>
        ↓ bind
<absolute system consumer>（/etc/...、/var/lib/...）
```

rule（`<machine-state-persistence-rule>`）：

```text
name      逻辑名
backing   machine-state root 相对路径
consumer  absolute system runtime path
exposure  仅 bind-directory
lifecycle 仅 machine-owned
```

### Root ownership layering

```text
storage/model.scm                     owns /persist/system（persist-mount-point）
machine-state-persistence.scm         owns /persist/system/state
未来 daemon 声明                     owns /persist/system/state/<daemon>/...
```

不新增 `/persist/system` 第二 authority；不创建全局 paths.scm /
path DSL。

## Invariants

1. canonical state 只有 `/persist/system/state/...` 一份；
2. `/etc`、`/var/lib` consumer 只是 projection；
3. 禁止 boot-copy/shutdown-copy 双副本同步；
4. 禁止自动迁移已有 consumer 数据；
5. backing 是 machine-state root 相对路径（无 absolute/`..`/empty/escape）；
6. consumer 必须 absolute，且不得位于 `/gnu/store`、`/run`、
   `/persist`、user HOME、`/proc`、`/sys`、`/dev`、`/tmp`；
7. exposure 仅 `bind-directory`；lifecycle 仅 `machine-owned`；
8. backing 创建走系统 activation（先于 file-systems 挂载——pinned
   Guix 行为，与 application-persistence 同一审计）；
9. 不新增 readiness capability（filesystem topology concern）；
10. 默认 root ownership（机器状态属 root）；真实 daemon 需要
    owner/group/mode 时，在 backing 与 consumer 两侧强制（bind
    语义：mount 后 consumer 可见权限 = backing 权限）——现有生产
    先例：mihomo（root，0700，mihomo activation 两侧强制）、
    noctalia-greeter（greeter 用户，0750：consumer 侧由 channel
    service 的 activation 负责，backing 侧由本仓库
    noctalia-greeter-backing-ownership-activation 负责）；generic
    层暂不扩展 owner/group/mode 字段，不建 ACL framework。

## 与 host secret 的区别（重要）

| | `<模块>/secrets/*.age`（与引用者同置） | `/persist/system/state/...` |
|---|---|---|
| authority | **repository** | **machine** |
| 来源 | declarative ciphertext → system generation → runtime plaintext | 本机运行期产生的 mutable state |
| 生命周期 | 随 repository 声明 | 独立于 repository 持久 |
| 例子 | mihomo 订阅 URL（system/mihomo/secrets/） | GUI 连接 Wi-Fi 后 NM 自己保存的 profile/password |

**declarative Wi-Fi credential 不应成为"记住用户在 GUI 中连接过
哪些 Wi-Fi"的常规机制**——日常 GUI-generated Wi-Fi configuration
属于 machine-owned mutable state；只有明确要 declaratively provision
某个网络时，才进入 encrypted declarative-secret 模型。

## NetworkManager connection profiles

Laptop 持久化 NetworkManager 自己保存的 keyfile connection profiles：

```text
/persist/system/state/network-manager/system-connections
    → /etc/NetworkManager/system-connections
```

`modules/guixcfg/system/network-manager-persistence.scm` 拥有具体 rule
与权限 activation。backing 和 consumer 都强制 `root:root`、`0700`；
不递归改 profile 文件（keyfile 内容/mode 由 NetworkManager 管理）。
pinned Guix 的 NetworkManager activation 也会 `mkdir-p` 同一 consumer，
该操作不会放宽已有目录；所有 activation 完成后 Shepherd 才启动挂载，
且 NetworkManager → `user-processes` → `file-systems` → connection bind，
因此 daemon 启动前 projection 已就位。

不持久化 `/var/lib/NetworkManager`：timestamps、seen-BSSID、DHCP 等
派生/易变状态不需要跨 ephemeral-root 保留。VM 也不接入该 rule。

## 现有 production rules

- **NetworkManager（Laptop only）**：GUI/user-created keyfile profiles，
  root-owned（0700）；只持久化 `system-connections`，不持久化
  `/var/lib/NetworkManager`。
- **machine-id**（system/machine-identity.scm + utils/machine-id.scm，
  2026-08-30）：`/persist/system/machine-id` → `/etc/machine-id`
  （activation 投影；不是 bind——单文件 atomic-replace 消费者）。
  per-machine identity：首启 `dbus-uuidgen` 生成一次，之后跨 reboot
  / root 重建稳定；绝不覆盖 canonical；必须先于 D-Bus activation 的
  dbus-uuidgen --ensure 执行（host 组装置 services 列表末尾，
  test-machine-identity.scm 断言时序）。详见
  docs/architecture/persistence.md（Machine identity）。
- **mihomo**（system/mihomo/service.scm）：providers cache + 选中
  节点/组状态，root-owned（0700，mihomo activation 强制）。
- **noctalia-greeter**（system/noctalia-greeter.scm，2026-08-28）：
  `/persist/system/state/noctalia-greeter` → `/var/lib/noctalia-greeter`
  ——greeter 的 mutable state（sync.toml、Noctalia Shell Sync 的壁纸、
  output 状态）。owner/mode 分层：consumer 侧由 virelith channel
  noctalia-greeter-service-type 的 activation 负责（idempotent、
  只修 owner/mode 0750、不触碰内容、兼容 bind mount），backing 侧
  （bind 权限来源）由本仓库的 backing-ownership activation 负责。
  declarative `greeter.toml` 由 upstream 默认值承担，本仓库不生成
  （见 graphics.md 登录链）。
