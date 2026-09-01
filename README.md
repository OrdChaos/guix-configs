# guix-configs

个人设备的 Guix System 配置、安装与维护工程。面向 VM 与 Laptop：

无状态根目录（Btrfs root generation）+ GPT/LUKS2/Btrfs + UKI/Limine +
Secure Boot + TPM2 PCR7 自动解锁（密码回退）+ age 秘密管理 + Guix
Home。

完整文档入口：[docs/README.md](docs/README.md)
（architecture / operations / development / reference）

## 快速概览

```text
repo + locked channels → system generation → UKI/Secure Boot
  → initrd（LUKS: TPM 或密码）→ root generation → persistent mounts
  → activation → readiness DAG → login/session/Home
```

## 常用命令

```bash
# 开发环境
guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm

# 测试（pinned Guix）
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm

# 磁盘安装器（inspect/plan 只读）
guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- inspect /dev/vda
guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- plan vm /dev/vda

# 构建 VM 系统配置（已装系统外需要 facts 文件，见 development/testing.md）
GUIX_CONFIG_FACTS=/tmp/facts.scm \
  guix time-machine -C channels.lock.scm -- system build -L "$PWD/modules" modules/guixcfg/hosts/vm.scm

# 日常入口（安装后，Blue 来自已部署 Guix Home profile）
blue doctor laptop
blue build-os laptop
blue reconfigure laptop
blue update            # 重写 channels.lock.scm（见 docs/operations/reconfigure.md）
blue check

# bootstrap / rescue / Blue self-upgrade（Blue 来自当前仓库 lock）
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- blue help
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- blue reconfigure laptop

# Flatpak 显式运维（唯一联网入口；全部 --user scope，
# 详见 docs/architecture/flatpak.md；机制在 (guixcfg flatpak reconcile)）
guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm -- blue flatpak sync
... blue flatpak status [--refresh]
... blue flatpak update
... blue flatpak update-runtimes
... blue flatpak remove <logical-name>
... blue flatpak remote-replace <remote-name>
... blue flatpak gc
```

安装流程见 [operations/installation.md](docs/operations/installation.md)；
测试 VM 见 [operations/vm-testing.md](docs/operations/vm-testing.md)。

## 规则速记

- 正式部署只从**干净的已提交工作区**启动（Phase 1 clean-tree gate；
  immutable snapshot execution 是未来工作），脏工作区可以 build 不能
  switch；
- 运行时链接只指向 `/gnu/store`、`/run`、`/persist`，禁止指向本
  仓库 checkout；
- 项目不变量见 [development/invariants.md](docs/development/invariants.md)。
