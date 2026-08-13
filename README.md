# guix-configs

个人设备的 Guix System 配置、安装与维护工程。面向 VM 和 Laptop 两台机器：

无状态根目录（Btrfs root generation）+ GPT/LUKS2/Btrfs + UKI/Limine + Secure Boot + TPM2 PCR7 自动解锁（密码回退）+ age 秘密管理 + Guix Home + Flatpak。

完整设计定义见 `docs/`：

- `docs/project-definition.md` — 入口与索引（含目录结构、开发顺序、设计原则）
- `docs/storage.md` — 存储模型、持久子卷、root generation、备份
- `docs/boot.md` — Secure Boot、UKI、TPM2 PCR7 解锁、内核模块签名
- `docs/system.md` — Host、软件分类、硬件与驱动、Flatpak、Mihomo
- `docs/secrets.md` — 配置/秘密/可变状态分类、age 秘密管理
- `docs/deployment.md` — 频道管理、部署规则、`configctl`、日常工作流
- `docs/installation.md` — 安装流程

## 仓库布局

```text
channels.scm          频道集合（上游来源）
channels.lock.scm     频道锁（实际使用的 commit）
manifests/            开发 / 安装环境 manifest
modules/guixcfg/      全部配置模块（-L modules 加入 load path）
tools/                命令行工具（disk-install 等）
files/                公开配置文件源码（niri 等）
secrets/              age 密文（明文永不入库）
docs/                 设计文档
```

## 常用命令

在 `configctl`（独立 Rust 工具）可用之前，直接使用以下命令：

```bash
# 进入开发环境
guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm

# 运行单元测试（代码依赖 (guix records)，须经锁定频道的 guix repl 运行）
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm

# 磁盘安装器：inspect / plan 是只读操作，可以随时跑
guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- inspect /dev/sda
guix time-machine -C channels.lock.scm -- repl tools/disk-install.scm -- plan vm /dev/vda

# apply 是破坏性操作，只在测试 VM 里运行（tools/test-vm.sh 启动 VM）:
#   tools/test-vm.sh /path/to/guix-system-install-x86_64-linux.iso
#   VM 内: mount -t 9p -o trans=virtio guix-configs /root/src
#          cd /root/src && guix repl tools/disk-install.scm -- apply vm /dev/vda

# 构建 VM 系统配置（host 模块文件末尾的裸 %os 让它同时是入口文件）
guix time-machine -C channels.lock.scm -- system build -L modules modules/guixcfg/hosts/vm.scm

# 安装（init 只接受“配置文件 + 目标”两个位置参数，不支持 -e）：
#   GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm \
#     guix time-machine -C channels.lock.scm -- system init -L modules modules/guixcfg/hosts/vm.scm /mnt
```

## 规则速记

- 正式部署只消费**已提交 Git commit 的只读快照**，脏工作区只能 build 不能 switch（`docs/deployment.md` 第 6 章）；
- 频道更新显式执行：更新锁 → 构建 → 检查 → 提交 → switch；
- 运行时链接只指向 `/gnu/store`、`/run`、`/persist`，禁止指向本仓库 checkout。
