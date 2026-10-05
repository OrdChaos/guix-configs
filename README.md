# guix-configs

个人 Guix System 配置工程，面向两个明确的 x86_64 目标：一台 QEMU 测试
VM 与一台 Lenovo Legion Y7000P 笔记本。仓库以锁定频道、Guix System、
Guix Home 和 Blue 编排器管理从安装到日常更新的完整生命周期。

完整文档索引见 [docs/README.md](docs/README.md)。首次阅读建议从
[架构概览](docs/architecture/overview.md) 开始。

## 支持目标

| Host ID | 部署后的 hostname | 用途 |
| --- | --- | --- |
| `vm` | `ordchaos-vm` | QEMU/OVMF/SWTPM 测试与安装验收 |
| `lenovo-legion-y7000p` | `ordchaos-lenovo-legion-y7000p` | 物理笔记本，含 Wi-Fi、NVIDIA PRIME、Bluetooth 与 TLP 策略 |

Host ID 是部署参数，不是任意主机名的别名。除 `blue reconfigure` 和
`blue converge` 外，所有接受主机的 Blue 命令都要求显式传入 Host ID。
这两个命令省略 Host ID 时，只会按当前 hostname 作精确映射；未知主机
会拒绝执行，不会猜测目标。

## 系统模型

```text
repository + channels.lock.scm
        |
        v
Guix System generation
        |
        v
signed UKI / Secure Boot (A/B + Recovery)
        |
        v
initrd: LUKS unlock (TPM2 PCR7 or passphrase)
        |
        v
Btrfs root generation (@root-N)
        |
        v
/persist mounts -> activation -> readiness DAG -> login / Guix Home
```

- 根目录是可回退的 Btrfs generation；Guix System generation 是另一条、
  相互独立的回滚轴。Guix Home 随系统 generation 构建并在启动时投影，
  没有独立的 Home generation 轴。
- 可变状态只保留一份 canonical backing：用户数据在
  `/persist/data-home`，应用状态在 `/persist/data-app`，可重新获取的大
  文件在 `/persist/data-nobackup`，机器状态在 `/persist/system/state`。
- 仓库只作为求值和部署输入，不是运行时依赖。运行时引用只能指向
  `/gnu/store`、`/run` 或 `/persist`。
- age 密文可以留在仓库中；明文 secret 只会发布到 `/run`。登录关键
  secret 失败会阻止登录，普通应用 secret 的失败不会阻止登录。

存储、启动、持久化和 secret 的完整设计分别见
[storage](docs/architecture/storage.md)、[boot](docs/architecture/boot.md)、
[persistence](docs/architecture/persistence.md) 与
[secrets](docs/architecture/secrets.md)。

## 仓库与频道

所有构建、测试和部署均使用 `channels.lock.scm` 锁定的频道，避免环境随
上游变化而漂移。`channels.scm` 只声明可更新的来源；`channels.lock.scm`
记录实际使用的提交。

```bash
git clone https://github.com/ordchaos/guix-configs.git
cd guix-configs

# 进入由锁定频道提供的开发环境。
guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm

# 不进入 shell 时，在命令前加上相同的 pinned 环境。
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- blue help
```

已部署机器上的 `blue` 来自最后一次成功部署的 Guix Home profile。若已
部署的 Blue 无法加载当前仓库，或在 bootstrap/CI/rescue 环境中，始终用
上面的 development manifest 形式运行 `blue`。

## 日常操作

以下命令从仓库根目录执行。已安装机器的默认 checkout 是
`~/Projects/guix-configs`；它位于持久化的 `Projects` 目录中。

```bash
# 只读的部署前检查：验证机器 facts、频道锁、host、工具与干净工作树。
blue doctor lenovo-legion-y7000p

# 构建系统配置；允许在脏工作树中运行。
blue build-os lenovo-legion-y7000p
blue build-os all
blue -n build-os lenovo-legion-y7000p

# 部署当前主机。省略 Host ID 时按 hostname 精确识别。
blue reconfigure
blue -n reconfigure
blue reconfigure lenovo-legion-y7000p

# 部署成功后，同步并更新用户级 Flatpak 应用与 runtimes。
blue converge
blue -n converge
```

`doctor`、`reconfigure` 和 `converge` 只接受干净且已提交的工作树；
`build-os` 刻意允许脏树用于验证。`reconfigure` 的 dry-run 只检查
system derivation/build plan，不进入 sudo、login gate、Shepherd 重启或
Guix Home 热激活。

系统更新和 Flatpak 更新是不同的操作：

```bash
# 更新频道锁。此命令不构建、不部署、不提交。
blue update
blue -n update

# 对更新后的锁：构建 -> 测试 -> git commit -> 部署。
blue build-os lenovo-legion-y7000p
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
git add channels.lock.scm
git commit -m 'chore(channels): update lock'
blue reconfigure

# Flatpak 始终为调用用户的 --user scope，绝不使用 sudo。
blue flatpak status
blue flatpak status --refresh
blue flatpak sync
blue flatpak update
blue flatpak update-runtimes
blue flatpak remove <logical-name>
blue flatpak remote-replace <remote-name>
blue flatpak gc
```

`blue converge [HOST]` 等价于成功 reconfigure 后依次执行 `flatpak sync`、
`flatpak update` 和 `flatpak update-runtimes`。若刚升级 NVIDIA 驱动，
先重启使运行中的内核模块更新，再运行 `converge` 以取得匹配的 GL
extension。

其他维护入口：

```bash
# 删除旧的 system generation root，不会运行全局 guix gc。
blue gc lenovo-legion-y7000p
blue gc lenovo-legion-y7000p --keep 2
blue gc lenovo-legion-y7000p --delete 0,3
blue -n gc lenovo-legion-y7000p

# 检查或投影仓库管理的 GSettings；必须在图形用户会话中以普通用户运行。
blue gsettings status
blue gsettings apply
blue -n gsettings apply

# 使用 pinned Guix style 格式化 Scheme；-n 仅检查将变更的文件。
blue format
blue format modules/guixcfg/hosts/vm.scm
blue -n format
```

`blue gc` 只移除 system generation 的 GC roots，不会释放 store 空间；
需要全局回收时，另行显式执行 `guix gc`。

## 安装与首次启动

安装是有 lifecycle guard 的一次性流程，而非日常部署入口。主路径、
前置条件与失败恢复见 [安装文档](docs/operations/installation.md)。

实机首次安装前，必须在固件界面清除 Secure Boot keys 并进入 Setup Mode
（`SecureBoot=0`、`SetupMode=1`）。否则安装 preflight 会在写盘前拒绝。
VM 的固件状态由测试 harness 管理，不适用此项实机要求。

```bash
# 在 LiveCD/installer 环境、仓库根目录中执行。
# 先执行零 mutation、无 sudo 的完整只读计划。
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- \
  blue -n install lenovo-legion-y7000p /dev/nvme0n1

# 确认目标设备后执行破坏性安装；命令会要求逐字输入完整设备路径。
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- \
  blue install lenovo-legion-y7000p /dev/nvme0n1

# 安装完成后不会自动重启。进入已安装系统后：
cd ~/Projects/guix-configs
blue -n firstboot lenovo-legion-y7000p
blue firstboot lenovo-legion-y7000p

# 重启到 firstboot 收敛后的 UKI 后，开始机器绑定 enrollment。
blue enroll lenovo-legion-y7000p

# 再重启一次，使 Secure Boot 生效并手工输入一次 LUKS 密码；随后完成 TPM enrollment。
blue enroll lenovo-legion-y7000p
```

`blue install` 会创建 GPT/LUKS2/Btrfs 布局、生成 Secure Boot 密钥、
写入 machine facts、安装 stable identity 和 password hash、执行 system
init、提交 root generation、复制仓库并验证结果。验证成功后它会停止
安装期 cow-store 并 `sync`，但不会自动卸载、关机或重启。

`blue firstboot` 只进行 system 和 Home 的 reconfigure；它不写固件变量
也不配置 TPM。`blue enroll` 分两次执行：第一次注册 PK/KEK/db，重启后
第二次根据最终 Secure Boot 状态进行 TPM2 PCR7 enrollment。完成这些
lifecycle 阶段后，日常更新应使用 `blue reconfigure`；TPM 或 Secure Boot
的修复使用安装文档和[恢复文档](docs/operations/recovery.md)中的显式底层
工具。

## 验证与测试

修改代码后依次运行目标测试、相关子系统测试和核心测试。默认 runner
只覆盖 core；应用专属检查必须显式要求。

```bash
# 必跑 core 测试。
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm

# 可选的应用测试，或 core 加应用测试。
guix time-machine -C channels.lock.scm -- repl -- tests/run-tests.scm --apps
guix time-machine -C channels.lock.scm -- repl -- tests/run-tests.scm --all

# Blue 对 core runner 的薄包装。
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- blue check

# 完整 VM operating-system 的 derivation 验证。
GUIX_CONFIG_FACTS=/tmp/facts.scm \
GUILE_LOAD_PATH="$PWD/modules" GUILE_LOAD_COMPILED_PATH="$PWD/modules" \
  guix time-machine -C channels.lock.scm -- system build \
  -e '(@ (guixcfg hosts vm) %vm-os)'
```

`blue -n check` 不运行测试，这是 Blue 的 dry-run 语义。对 kernel、
toolchain 等昂贵包，先以 `guix build --dry-run` 检查 substitute 计划；
不要在 REPL 中用 `package-derivation` 作 probe，它可能实际触发构建。

```bash
guix time-machine -C channels.lock.scm -- build --dry-run \
  -L "$PWD/modules" -e '(@ (guixcfg system kernel-platform) %kernel)'
```

QEMU fresh-install、Secure Boot 与 TPM E2E 验收见
[VM 测试文档](docs/operations/vm-testing.md)：

```bash
# 从 ISO 启动安装环境。
tools/test-vm.sh --secboot /path/to/guix-system-install-x86_64-linux.iso

# 从测试磁盘启动。
tools/test-vm.sh --secboot
```

不要以 Ctrl-C 终止 QEMU；请在 guest 中关机或经 QEMU monitor 发出
`system_powerdown`。

## 设计约束

- 每个事实、可变运行时资源和 persistent backing 都只能有一个权威
  定义或 writer。
- 可重建的产物，包括 Guix Home 生成物、UKI/build artifact 和 cache，
  不持久化。
- 重要状态转换必须原子化；登录与启动关键路径必须先验证最终状态再提供
  readiness capability。
- 新的应用配置放在 `modules/guixcfg/apps/<name>/` 中，经显式 registry
  启用；不扫描目录，也不建立自制的 NixOS module framework。
- 不在运行时读取 checkout，也不通过开机复制实现持久化；仓库是
  `Projects` backing 中的普通项目目录。

完整且不可违背的规则见
[development/invariants.md](docs/development/invariants.md)，贡献约定见
[development/conventions.md](docs/development/conventions.md)。

## 文档导航

- [文档总览](docs/README.md)
- [架构概览](docs/architecture/overview.md)
- [账户、登录与会话](docs/architecture/accounts-sessions.md)
- [Guix Home 与 application layer](docs/architecture/home.md)
- [Flatpak 架构与运维边界](docs/architecture/flatpak.md)
- [GSettings 投影](docs/architecture/gsettings.md)
- [安装流程](docs/operations/installation.md)
- [日常 reconfigure 与频道管理](docs/operations/reconfigure.md)
- [恢复](docs/operations/recovery.md)
- [VM 与 E2E 测试](docs/operations/vm-testing.md)
- [测试层级](docs/development/testing.md)
- [仓库布局](docs/reference/repository-layout.md)
