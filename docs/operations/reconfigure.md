# Reconfigure

日常已安装系统的更新流程。安装见 `operations/installation.md`。

## Blue 入口（Phase 1 推荐）

Blue（repository orchestrator）是日常编排入口。已部署系统上 `blue`
直接来自 **Home profile**（`~/.guix-home/profile/bin/blue`，Blue 是
一个 application：`(guixcfg apps blue)`，package 来自 pinned bluebox
channel）：

```bash
blue help
```

**两个 Blue 来源的语义边界**：

```text
installed Blue       = 当前最后一次成功部署的 Guix Home generation
                       → 对应上一次成功 reconfigure 时的
                         channels.lock.scm
                       → 正常日常入口

development manifest Blue
                     = 当前 repository channels.lock.scm 指定的 Blue
                       → bootstrap / CI / rescue / Blue self-upgrade
```

Blue 是 pre-alpha：可能出现 installed Blue 无法加载已更新要求新
API 的 blueprint.scm 的情况。此时 rescue 路径是：

```bash
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- blue ...
```

development manifest 就是 bootstrap boundary，不需要额外 wrapper。

```bash
# 基本操作（HOST 恒显式：vm / laptop）
blue doctor laptop        # 部署就绪检查（离线、只读；脏工作区 fail）
blue build-os laptop      # 构建系统配置（脏工作区允许）
blue -n build-os laptop   # 构建 dry-run（derivation plan，不产 store）

blue reconfigure laptop   # 部署（前置 doctor + git clean gate）
blue -n reconfigure laptop

blue check                # 测试套件（薄包装 tests/run-tests.scm）
blue update               # 重写 channels.lock.scm（见下）
blue -n update

# Flatpak 用户应用生命周期（user scope；见 architecture/flatpak.md）
blue flatpak status [--refresh]
blue flatpak sync
blue flatpak update
blue flatpak update-runtimes
blue flatpak remove <logical-name>
blue flatpak remote-replace <remote-name>
blue flatpak gc
```

`blue update`（频道锁更新）与 `blue flatpak update`（Flatpak 应用
更新）是两个不同的操作,不可混用。Flatpak 属于 user application
lifecycle,不属于 system provisioning。

## Host

- **EXPLICIT HOST ONLY**：`reconfigure` / `build-os` / `doctor` 的位置
  参数必须显式给出 host ID；`build-os all` 构建全部 host（CI 用）。
- 无参数**绝不 fallback**（尤其不回退 vm）——报错并列出已知 host。
- host ID 的事实源是 `modules/guixcfg/hosts/*.scm` 的文件名
  （`(guixcfg hosts selection)` 目录枚举）；不做 hostname 自动检测、
  不加载完整 operating-system 取 host-name。
- 文档示例只写当前两个 host，**权威 host list 不在此手工维护**。

## Dirty tree 契约

```text
build-os          dirty worktree allowed（无 git gate）
doctor / reconfigure  dirty worktree rejected（fail closed）
```

部署契约（Phase 1）：

> deployment starts only from a clean committed worktree

当前 Phase 1 gate **不提供 immutable snapshot execution**——reconfigure
只保证启动时工作树 == HEAD，并记录 HEAD 供结束后漂移检查（漂移仅
WARNING）。真正从固定 commit 快照执行（Level 2）是未来工作，见
`development/roadmap.md`。

## 正式入口的机制

`blue reconfigure HOST` = doctor preflight（含 git clean gate）→
privilege handoff（`sudo <同一个 blue> -f <仓库 blueprint.scm>
.reconfigure-root HOST HOME-USER`，root phase 非 root 直接拒绝）→
`(guixcfg system reconfigure)` gate transaction（Guile 实现，机制
事实源）→ postflight 漂移检查。transaction 返回 0/1/2，Blue 原样
传播。

事务语义（(guixcfg system reconfigure)）：

```text
关闭 login gate（新 session 拒绝；已有 session 不动）
  → guix time-machine … system reconfigure
  → shepherd 升级自动 restart 变化的 one-shot 服务
    （runtime secrets 代际发布、account verify、Home 热激活）
  → 验证 Home 链接与 readiness capability 无 failed
  → 打开 gate
```

失败语义（exit code 契约）：

```text
reconfigure 失败          → gate 重开（无状态变化），exit 1
system 成功 + Home 失败   → gate 保持关闭，exit 2；
                            修复后重跑 blue reconfigure HOST
                            恢复（无需 reboot）
```

## 什么时候需要 reboot

- 内核/initrd/UKI 变化：boot 才生效。
- 纯 Shepherd 服务/activation 变化：reconfigure 热生效。
- gate 卡住（某 capability failed）：修复后重跑
  `blue reconfigure HOST`，无需 reboot。

## 手动等价命令

```bash
GUIX_CONFIG_FACTS=/persist/system/facts/host.scm \
  guix time-machine -C channels.lock.scm -- system reconfigure \
  -L "$PWD/modules" modules/guixcfg/hosts/vm.scm
```

日常验证：`guix system describe`、`herd status`、`guix home` 链接。

## doctor

> deployment readiness check：现在执行 reconfigure，仓库与机器状态
> 是否满足部署前置条件？

检查项（完全离线，不查询 upstream）：

```text
repository root（marker-based，channels.lock.scm 所在目录）
channels.lock.scm 存在
modules/ 存在（guix -L 目标）
machine facts：复用 (guixcfg system machine-facts) 的 resolution
  policy（GUIX_CONFIG_FACTS → /persist/system/facts/host.scm）；
  路径存在、可解析、含 boot-critical fact（luks-uuid）
tools：guix / git / sudo 在 PATH
host id 已知、host 文件存在
git worktree clean（dirty → fail closed）
channels.scm 与 channels.lock.scm 结构兼容
  （name/url/branch/introduction；不比较 revision）
```

同时打印当前 HEAD（供 reconfigure 后漂移检查参考）。

## Dry-run 契约（逐命令）

| 命令 | dry-run 语义 |
| --- | --- |
| `blue -n build-os HOST` | 下游 `guix system build --dry-run`：真实 derivation/build plan（保留 facts/module lowering 验证），不构建 store object |
| `blue -n reconfigure HOST` | 只读前置照常执行（含 git clean gate），然后 `guix system reconfigure --dry-run`。**只验证 system derivation/build plan**——不模拟 gate 事务、shepherd restart、Home 热激活；**绝不进入 privileged transaction（无 sudo、无 gate、无 herd）** |
| `blue -n update` | **command preview only**：不联网、不解析新 revision、不写锁；只打印将执行的命令与目标文件。无法预告"将更新到什么 commit" |
| `blue -n check` | 不真正运行测试套件（Blue testable builtin dry-run 语义，有意为之） |
| `blue doctor` | 本身只读，检查照常执行 |

## update

语义严格限定：

> resolve mutable `channels.scm`，原子重写 `channels.lock.scm`

- 不做 build / reconfigure / deployment / `guix pull` / profile 更新；
- **不 `git add` / `git commit` / `git push`**——锁重写后按频道管理
  流程人工构建、检查、提交；
- 复用 `(guixcfg utils atomic-file)` 的原子写；成功后打印
  old → new commit 摘要，不自动做下一步。

## 部署规则

- 正式部署只从**干净的已提交工作区**启动；脏工作区只能 build 不能
  switch（`blue build-os` 允许脏，`blue doctor`/`blue reconfigure`
  fail closed）。
- 频道更新显式执行：`blue update`（更新锁）→ 构建 → 检查 → 提交 →
  switch。
- 运行时链接只指向 `/gnu/store`、`/run`、`/persist`，禁止指向仓库
  checkout。

## 频道管理

```text
channels.scm        频道集合与上游来源（Guix、Nonguix、Rosenthal、
                    virelith、saayix、bluebox 按需）
channels.lock.scm   固定实际使用的 commit / introduction / branch
```

所有构建与部署经 `guix time-machine -C channels.lock.scm` 运行。
`system switch` / `home switch` 不能隐式更新频道。

**频道镜像与 substitutes 分离**：Git channel URL（获取源码）与
substitute URL（下载预构建 store item）配置分开；LiveCD 环境使用
代理。不需要的频道删除，不为"以后可能用"永久保留。

更新过程（显式、不可隐式）：

```text
blue update（更新锁）→ 构建 → 检查 → 提交 → switch
```
