# Repository-derived GSettings

静态应用偏好（GSettings schema/key/value）的仓库派生投影机制：
application 在自己的 definition 声明它负责的 GSettings；仓库统一
聚合、校验 ownership 并投影到 runtime dconf。

## 核心不变量

```text
repository      = source of truth
GSettings 声明  = declarative desired state
dconf           = disposable runtime projection
reboot          = natural reset boundary
```

**`~/.config/dconf` is intentionally not persisted**——无任何
persistence declaration（最终 grep 门禁），dconf runtime DB 每 boot
从声明重建。

**Removing a repository declaration may leave the old runtime value
until the next reboot. This is intentional: reboot is the stateless
reset boundary.** 不实现 generation managed-key tracking、不保存
managed-key metadata、不 `dconf reset` 已删除键——这不是遗漏，是
设计选择（无状态模型的自然语义）。

## 架构

```text
application definition
    │  (gsettings (list <gsettings-setting> ...))   ← contribution container
    ▼
applications-gsettings（apps/model.scm，owner pairs）
    ▼
validate-gsettings-ownership!
    ├─ (schema,key) 单一 owner（重复即 fail，即使值相同；错误列出全部 owner）
    └─ appearance 保留域冲突即 fail（见下）
    ▼
serialize（schema→dconf path；schema/key 确定性排序；key=value，
            value 为 GVariant 文本原样透传）
    ▼
dconf load /（唯一 mutation 后端）
    ▼
~/.config/dconf（disposable runtime DB，绝不持久化/生成/复制/symlink）
```

语义模型叫 GSettings；dconf 只是当前 projection backend。value 是
dconf/GSettings tooling 接受的 GVariant 文本表示（`"true"` /
`"12"` / `"'Adwaita'"` / `"['foo', 'bar']"`）——Phase 1 不设计
GVariant 类型系统，声明作者负责写合法文本；runtime 侧由
`gsettings list-keys` / `gsettings range`（浅层校验）与 dconf load
自身接受性兜底。

## Ownership 契约

- 一个 managed GSettings key = 恰好一个 application owner。
- 重复 `(schema,key)`（即使值相同）→ fail，无 last-wins、无
  silently merge、无 registry 顺序决定。
- owner 信息在 aggregation 阶段以 pairs 保留（错误报告用），不
  塞进 record 重复存字符串。
- managed key = 仓库声明中的键；**unmanaged key = 其它一切**——
  reconcile 只写 managed 声明，绝不 reset/删除 unmanaged 状态。

## Appearance 边界

`org.gnome.desktop.interface` 的 6 个动态外观键由既有
appearance-sync（apps/gtk/definition.scm）**独占**——Noctalia
light/dark 切换会在运行时改写它们：

```text
color-scheme  gtk-theme  icon-theme  cursor-theme  cursor-size  font-name
```

边界：

```text
dynamic desktop appearance    → existing appearance-sync
ordinary static app preferences → generic GSettings
```

`%appearance-owned-gsettings-keys`（gsettings/model.scm）是机制级
强制：generic 声明任何保留键 → ownership 冲突 fail（不是只靠测试）。

## Projection lifecycle

| 时刻 | 发生什么 |
|---|---|
| login | Home Shepherd one-shot `gsettings-reconcile`（requirement `(dbus)`）把声明投影进 runtime dconf |
| reconfigure | Home generation 更新 → 内嵌声明的 wrapper 变 → Shepherd 重跑 one-shot → 立即生效（无需手工 apply） |
| manual | `blue gsettings apply`（inspection / repair / manual reconcile） |
| reboot | ephemeral dconf DB 重建；已删除声明的旧值自然回 schema default |

service 不放在普通 Home activation（activation 时 user D-Bus 未
就绪）；one-shot + dbus 依赖才是正确接线。wrapper 是 program-file
gexp（无 shell 字符串），desired 声明在 **build time 嵌入**。

## Blue interface

```text
blue gsettings status       真实只读 desired/current diff（五态）
blue gsettings apply        validate → serialize → dconf load /
blue -n gsettings apply     真实只读 diff + plan，零 mutation
                            （绝不 invoke dconf load）
```

status 每键五态：`synced` / `drifted` / `missing-schema` /
`missing-key` / `invalid-desired-value`；apply 对后三类 fail-loud
（不 silent ignore）。root 调用被拒绝（root 进程的 dconf 落在
`/root/.config/dconf`，是与真实用户完全平行的错误作用域）。

**执行面在 pinned 子进程**（`blue gsettings …` → `guix
time-machine -C channels.lock.scm -- repl tools/gsettings.scm -- …`）：
desired state 事实源 apps registry 的 39 个 definition 含 8 个
channel 模块依赖，且引用的 guix 包必须来自 pinned channels——
`guix time-machine shell` 的 GUILE_LOAD_PATH 只带宿主机 guix
current，直接解析 registry 不可靠；blueprint 编译期导入非平凡新
模块也会触发 guile 链接期崩溃（决策记录见 tools/gsettings.scm
与 blueprint.scm §3.7 注释）。与 `blue check` →
tests/run-tests.scm 同一模式。

## 当前 consumer

| application | schema | 键 | 值 |
|---|---|---|---|
| gnome-text-editor | org.gnome.TextEditor（pinned 48.3 实测） | custom-font | `'Monospace 11'` |
| | | highlight-current-line | `true` |
| | | indent-style | `'space'` |
| | | show-line-numbers | `true` |
| | | show-right-margin | `false` |
| | | style-scheme | `'Adwaita'` |
| | | use-system-font | `false` |

`restore-session` 有意不声明（保持 schema default）：未保存草稿经
application-data 持久化恢复，不依赖 session 恢复机制。

## 模块布局

```text
modules/guixcfg/gsettings/model.scm         <gsettings-setting> + 校验 +
                                            ownership 硬规则 + appearance 保留域
modules/guixcfg/gsettings/serialize.scm     schema→dconf path + 确定性 keyfile
modules/guixcfg/gsettings/reconcile.scm     status/plan/apply!（PATH 解析工具，
                                            无 registry、无具体 app 设置）
modules/guixcfg/gsettings/home-service.scm  one-shot session service + wrapper
tools/gsettings.scm                         pinned repl 执行入口（blue 调度）
```
