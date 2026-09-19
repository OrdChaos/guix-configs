# Reconfigure

日常已安装系统的更新流程。安装见 `operations/installation.md`。

## Blue 入口（Phase 1 推荐）

Blue（repository orchestrator）是日常编排入口。已部署系统上 `blue`
直接来自 **Home profile**（`~/.guix-home/profile/bin/blue`，Blue 是
一个 application：`(guixcfg apps blue definition)`，package 来自 pinned bluebox
channel）：

```bash
blue help

# 生命周期入口一览
blue doctor HOST             # 部署就绪检查（离线只读）
blue build-os HOST           # 构建系统配置（允许脏工作树）
blue reconfigure [HOST]      # 部署；省略 HOST 时按本机 hostname 精确识别
blue install HOST DEVICE     # 安装生命周期（LiveCD；见 installation.md）
blue firstboot HOST          # 首次启动收敛：reconfigure + enroll（见 installation.md）
blue enroll HOST             # 机器绑定 enrollment（目标系统上；见 installation.md）
blue gc HOST                 # 删除旧 system generation（不跑 guix gc）
blue update                  # 重写 channels.lock.scm
blue check                   # 核心测试套件（应用专属测试不默认运行）
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
# 基本操作（除 reconfigure 可识别本机外，HOST 恒显式）
blue doctor lenovo-legion-y7000p        # 部署就绪检查（离线、只读；脏工作区 fail）
blue build-os lenovo-legion-y7000p      # 构建系统配置（脏工作区允许）
blue -n build-os lenovo-legion-y7000p   # 构建 dry-run（derivation plan，不产 store）

blue reconfigure                         # 本机部署（前置 doctor + git clean gate）
blue -n reconfigure                      # 本机部署 dry-run
blue reconfigure lenovo-legion-y7000p    # 显式形式；hostname 变更/修复时使用

blue firstboot lenovo-legion-y7000p     # 首次启动收敛：reconfigure 相位 + enroll 相位
blue -n firstboot lenovo-legion-y7000p  # 只读：reconfigure 推导 plan + enrollment 计划

blue check                # 测试套件（薄包装 tests/run-tests.scm）
blue update               # 重写 channels.lock.scm（见下）
blue -n update

# system generation 删除（Guix 轴；见 architecture/storage.md）
blue gc lenovo-legion-y7000p            # 按 policy 保留
blue gc lenovo-legion-y7000p --keep 2   # 覆盖保留数
blue gc lenovo-legion-y7000p --delete 0,3
blue -n gc lenovo-legion-y7000p         # 只读 plan

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

- `build-os` / `doctor` 及生命周期命令保持 **EXPLICIT HOST ONLY**；
  `build-os all` 构建全部 host（CI 用）。
- `reconfigure` 可省略 Host ID：当前 hostname 必须在
  `(guixcfg inventory hosts)` 中精确映射到一个现存 Host ID。
  inventory 在模块加载时强制 Host ID 和 hostname 分别唯一；未知、
  重复或映射不一致时 fail closed，绝不猜测或回退 `vm`。
- hostname 改名尚未部署或身份映射需要修复时，使用显式
  `blue reconfigure HOST`。
- host ID 的事实源是 `modules/guixcfg/hosts/*.scm` 的文件名
  （`(guixcfg system deploy)` 目录枚举）；Host ID 与 hostname 的映射
  事实源是 `(guixcfg inventory hosts)`，host 模块也使用该映射
  生成 `operating-system` 的 `host-name`。
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

`blue reconfigure [HOST]` = 本机身份解析（省略 HOST 时）→ doctor preflight（含 git clean gate）→
privilege handoff（`sudo <同一个 blue>
--store-directory=/run/guixcfg/.blue-store -f <仓库 blueprint.scm>
.reconfigure-root HOST HOME-USER`，root phase 非 root 直接拒绝；
root 进程的 Blue store 指向 /run 的项目命名空间，绝不向用户仓库
的 .blue-store 写入 root 所有文件——否则之后普通用户运行 blue 会
因打不开 .lock 报权限不足）→
`(guixcfg system reconfigure)` gate transaction（Guile 实现，机制
事实源；gate 的 path/close/open 唯一 authority 是
(guixcfg system session-gate)）→ postflight 漂移检查。transaction
返回 0/1/2，Blue 原样传播。

事务语义（(guixcfg system reconfigure)）：

```text
关闭 login gate（新 session 拒绝；已有 session 不动）
  → guix time-machine … system reconfigure --no-kexec
  → shepherd 升级自动 restart 变化的 one-shot 服务
    （runtime secrets 代际发布、account verify、Home 热激活）
  → gvfs-mount-metadata one-shot 每轮落入 to-start 重跑（pinned guix
    语义：停止态 one-shot 每轮 start-service）——mount topology 变化
    同轮重建 utab，无需 reboot（docs/architecture/home.md）
  → Home generation 切换后，Home Shepherd 重跑 gsettings-reconcile
    one-shot（desired 声明 build-time 嵌入 wrapper——声明变即重跑，
    runtime dconf 立即更新；docs/architecture/gsettings.md）
  → 通过 Shepherd protocol 验证 Home 链接与 readiness capability 状态
  → 打开 gate
```

失败语义（exit code 契约）：

```text
reconfigure 失败          → gate 重开（无状态变化），exit 1
system 成功 + Home 失败   → gate 保持关闭，exit 2；
                            修复后重跑 blue reconfigure HOST
                            恢复（无需 reboot）
```

reconfigure 的 guix argv 固定带 `--no-kexec`：pinned guix 默认在
reconfigure 完成时用 `kexec_file_load` 把新 kernel/initrd 预载进内存
（供 `reboot --kexec` 免固件重启）；本系统不需要，显式关闭。
上游 Guix 的 operating-system 定义没有声明式开关，只能传 CLI flag
（`deploy.scm` 的 `%reconfigure-options`；dry-run argv 同形）。

`blue firstboot HOST` = 同一 reconfigure 机制（doctor → handoff →
gate transaction → drift check）成功后，接着执行 `blue enroll HOST`
的完整机制（installation.md「首次启动」）。两个相位与两个单命令
共用同一实现（blueprint 的 %reconfigure-host / %enroll-host），
任一相位失败即整体失败（该相位退出码），绝不跳过失败继续。该入口
只允许首次执行：固件 PK 已写入后，持久化 enrollment facts 会让
lifecycle guard 在 reconfigure 之前阻断；后续更新使用普通
`blue reconfigure HOST`。

## 什么时候需要 reboot

- 内核/initrd/UKI 变化：boot 才生效。
- 纯 Shepherd 服务/activation 变化：reconfigure 热生效。
- gate 卡住（某 capability failed）：修复后重跑
  `blue reconfigure HOST`，无需 reboot。

## system generation 删除（blue gc）

旧 system generation 的删除是显式入口，不是全自动服务：

```text
blue gc HOST                    按 host policy（keep-root-generations）
                                保留最新 generation
blue gc HOST --keep N           覆盖 policy
blue gc HOST --delete LIST      LIST 逗号分隔、支持 3..5 区间
```

- current 与 last-good generation 永不删除；generation 0 由 Guix
  （delete-generation）保护。
- 域逻辑在 `(guixcfg system system-generations)`，执行在
  `tools/gc-cli.scm`（pinned 子进程）；`blue gc` 经 sudo handoff 到
  内部 `.gc-root`（写 `/var/guix/profiles` 需要 root）。
- 用 `guix package -p <system-profile> --delete-generations=...` 而非
  `guix system delete-generations`：后者会 `reinstall-bootloader`，经
  `lookup-bootloader-by-name` 在 profile 的 `gnu/bootloader` 命名空间查
  自定义 `uki` bootloader——必然失败（见 storage.md）。
- `blue reconfigure HOST` 成功后**自动**执行同一步（按 policy，
  best-effort：失败只 WARNING，不改变已成功部署的退出码）。

**`blue gc` 不运行 `guix gc`**：删除 generation 只是移除 GC root，
不释放 store 空间。有意不自动 `guix gc`——它是全 store 级的，会连带
回收所有失去 root 的 on-demand store 内容（例如 guix-rust-toolchain
代理 realize 的 toolchain：其 GC root 在 ephemeral 的
`~/.cache/guix-rust-toolchain/roots/`，跨 boot 即失效）。需要释放空间
时自行显式运行 `guix gc`。

Btrfs 轴（`@root-N` 子卷）由系统 activation 的 `ephemeral-root-cleanup`
按同一 policy 自动清理（见 architecture/storage.md）；两轴共用保留算法
与 policy。

## 手动等价命令

```bash
GUIX_CONFIG_FACTS=/persist/system/facts/host.scm \
  env GUILE_LOAD_PATH="$PWD/modules" GUILE_LOAD_COMPILED_PATH="$PWD/modules" \
  guix time-machine -C channels.lock.scm -- system reconfigure --no-kexec \
  modules/guixcfg/hosts/vm.scm
```

（库模块经 `GUILE_LOAD_PATH` 注入，不用 `-L`——`-L` 会把
`modules/` 加进包搜索路径，见 `deploy.scm` 的 `modules-load-path-env`。
`--no-kexec` 见「正式入口的机制」。）

日常验证：`guix system describe`、`herd status`、`guix home` 链接。

## doctor

> deployment readiness check：现在执行 reconfigure，仓库与机器状态
> 是否满足部署前置条件？

检查项（完全离线，不查询 upstream）：

```text
repository root（marker-based，channels.lock.scm 所在目录）
channels.lock.scm 存在
modules/ 存在（GUILE_LOAD_PATH 注入目标）
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
| `blue -n reconfigure [HOST]` | 只读前置照常执行（含 git clean gate），然后 `guix system reconfigure --dry-run`。**只验证 system derivation/build plan**——不模拟 gate 事务、shepherd restart、Home 热激活；**绝不进入 privileged transaction（无 sudo、无 gate、无 herd）** |
| `blue -n firstboot HOST` | 先执行一次性 lifecycle guard；未完成时运行 reconfigure 相位 dry-run（同 `-n reconfigure`）+ enroll 相位只读计划（同 `-n enroll`）。已写入固件 PK 时在 derivation 计算前阻断；始终零 mutation、无 sudo、无确认 |
| `blue -n update` | **command preview only**：不联网、不解析新 revision、不写锁；只打印将执行的命令与目标文件。无法预告"将更新到什么 commit" |
| `blue -n check` | 不真正运行测试套件（Blue testable builtin dry-run 语义，有意为之） |
| `blue -n gc HOST` | `tools/gc-cli.scm plan`：只读列出 existing/current/last-good/to-delete；不删除、无 sudo |
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
