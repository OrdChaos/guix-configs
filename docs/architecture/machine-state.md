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
10. 默认 root ownership（机器状态属 root）；未来真实 daemon 需要
    owner/group/mode 时按最小 contract 扩展，不建 ACL framework。

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

## NetworkManager（canonical example，未启用）

未来预期形态（**不是已确认的 production contract**）：

```text
/persist/system/state/network-manager/system-connections
    → /etc/NetworkManager/system-connections

/persist/system/state/network-manager/lib
    → /var/lib/NetworkManager
```

启用前必须再次审计（pinned Guix 94a84f9）：

- `network-manager-service-type`（gnu/services/networking.scm:1491；
  其 activate 已 `mkdir-p /etc/NetworkManager/system-connections`）；
- NM 当前实际 keyfile location；
- `/var/lib/NetworkManager` 中哪些 state 真正需要 persistence；
- owner/group/mode；
- `/etc` mountpoint topology（bind 挂到 /etc 子路径的行为）；
- service/mount ordering；
- Polkit/GUI connection-save semantics。

当前状态：**architecture can support it；production rule NOT enabled**
（generic mechanism + synthetic tests；无真实 NM service/rule）。
