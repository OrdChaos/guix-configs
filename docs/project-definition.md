# Guix 多机器无状态系统：项目定义

本文档是项目定义的入口，包含项目定位、仓库体系、目标机器、用户模型、可复现边界，以及目录结构、开发顺序和最终设计原则。其余章节按主题拆分：

- `deployment.md` — 滚动且稳定、频道管理、主仓库位置、仓库与运行系统的关系、`configctl`、日常工作流（第 6–9、29、33 章）
- `storage.md` — 持久化命名、磁盘布局、持久子卷、root generation、机器事实、存储边界、安装器安全要求、备份（第 10–13、17–20、31、34 章）
- `secrets.md` — 静态配置、秘密和可变状态、age 秘密管理（第 14–15 章）
- `boot.md` — Secure Boot、UKI、TPM、内核模块签名（第 16 章）
- `system.md` — Host 模型、Guix System 与 Guix Home、软件分类、硬件与驱动、Flatpak、Rust 工具链、niri、Mihomo（第 21–28 章）
- `installation.md` — 安装流程（第 30 章）

章节编号在全部文件中保持唯一和连续，跨文件引用直接使用章节号。

---

# 1. 项目定位

项目主仓库名称：

```text
guix-configs
```

安装完成后的用户可见路径：

```text
~/guix-configs
```

这是一个面向个人设备的 Guix System 配置、安装与维护工程。

当前目标机器：

```text
VM
Laptop
```

系统模型：

```text
Guix System
+ Guix Home
+ 多机器配置
+ GPT / LUKS2 / Btrfs
+ 无状态根目录
+ UKI / Limine
+ Secure Boot / TPM2
+ age 整文件秘密管理
+ Flatpak 用户应用
+ Mihomo 系统服务
+ 持久化和备份
```

本项目不是：

- 通用 Linux 发行版；
- 通用磁盘分区框架；
- NixOS module system 的 Scheme 复刻；
- 面向任意文件系统的磁盘 DSL；
- 面向大量用户和大量服务器的配置平台；
- 依赖 RDE 等额外大型配置框架的系统。

设计优先级：

```text
可理解
可验证
可恢复
可审计
可逐步扩展
```

而不是追求最大程度的抽象和通用性。

---

# 2. 仓库体系

整个工程由四个独立 Git 仓库组成。

## 2.1 `guix-configs`

位置：

```text
~/guix-configs
```

职责：

- VM 和 Laptop 的最终系统配置；
- 存储模型与安装器；
- Guix System 服务组合；
- Guix Home 用户环境；
- UKI、Limine、Secure Boot、TPM 配置；
- 持久化规则；
- age 加密 secret 的密文；
- Flatpak 用户应用声明；
- 备份策略；
- 频道声明和频道锁；
- 面向 `configctl` 的仓库协议。

它是系统的：

```text
配置源码
期望状态
部署输入
恢复入口
```

## 2.2 `personal-channel`

职责：

- 自用字体；
- 上游 Guix 尚未提供的软件；
- 自用 package definitions；
- `configctl` 的 Guix package；
- `mihomo-remote` 的 Guix package；
- 必要的自定义 Rust 工具链；
- 真正具有复用价值的 Guix service 或 package。

它是独立的 Guix channel。

`guix-configs` 依赖它，但它不依赖 `guix-configs`。

## 2.3 `configctl`

独立 Rust 应用。

职责：

- 从任意工作目录定位 `~/guix-configs`；
- 确定当前 host；
- 检查 Git 状态；
- 检查配置 commit；
- 创建只读部署快照；
- 调用 `guix time-machine`；
- 调用 `guix system`；
- 调用 `guix home`；
- 编排磁盘检查、计划、安装和部署；
- 管理必要的权限提升；
- 记录实际部署 revision。

它不负责：

- 解析 Scheme；
- 定义 `<operating-system>`；
- 定义 Guix Home；
- 决定软件包列表；
- 定义磁盘布局；
- 组合系统服务；
- 维护第二套配置语言。

它是部署控制器，不是配置系统。

## 2.4 `mihomo-remote`

独立 Rust 应用。

目标能力：

```text
列出订阅
切换订阅
更新订阅
列出节点
切换节点
列出代理模式
切换代理模式
启动 Mihomo
停止 Mihomo
查看 Mihomo 状态
调用 Mihomo API
```

不再依赖 Clash Verge 作为主要管理界面。

依赖关系：

```text
configctl ───────┐
                 │ 被打包
mihomo-remote ───┤
                 ▼
          personal-channel
                 │
                 ▼
           guix-configs
```

---

# 3. 目标机器

## 3.1 VM

用途：

- 安装器开发；
- 磁盘操作测试；
- 加密启动测试；
- root generation 测试；
- UKI 和 Limine 测试；
- 在不破坏真实机器的前提下验证完整重装。

初始目标：

```text
x86_64
UEFI
QEMU / libvirt
目标磁盘通常为 /dev/vda
```

VM 安装阶段必须显式传入目标设备，不能把 `/dev/vda` 写成不可覆盖的默认擦除目标。

## 3.2 Laptop

目标硬件：

```text
Intel Core i7-13620H
Intel UHD Graphics
NVIDIA RTX 4050 Laptop
Intel AX211
NVMe SSD
UEFI
```

桌面方向：

```text
Wayland
niri
Noctalia
greetd
fcitx5
Intel + NVIDIA 混合显卡
```

Laptop host 需要处理：

- Intel 核显；
- NVIDIA 独显；
- 固件；
- 电源管理；
- Runtime D3；
- NVIDIA 专有驱动；
- Nonguix；
- Secure Boot；
- TPM2；
- 实际磁盘 by-id；
- 桌面、开发和游戏配置。

---

# 4. 用户模型

系统面向：

```text
root
+ 一个主要普通用户
```

主要用户环境由 Guix Home 管理。

不以多用户、多租户或公共服务器为主要目标。

---

# 5. 可复现边界

本项目追求：

> 从固定输入重建出软件版本、系统服务、磁盘拓扑和行为一致的机器。

不追求：

> 整块磁盘逐字节完全相同。

## 5.1 由仓库复现的内容

包括：

```text
磁盘分区结构
ESP 大小策略
LUKS2 与 Btrfs 层次
持久子卷名称
子卷挂载关系
swapfile 策略
系统软件包
用户软件包
服务配置
用户和用户组
内核参数
Guix Home
niri 等公开配置
UKI 生成规则
Limine 启动规则
持久化规则
Flatpak 应用期望集合
Mihomo 服务
备份策略
```

完整的软件配置输入为：

```text
guix-configs Git commit
+ channels.lock.scm
+ 目标 host
+ 必要的机器事实
```

## 5.2 重新生成但结构一致的内容

重装时允许变化：

```text
GPT PARTUUID
LUKS UUID
LUKS salt
Btrfs UUID
VFAT UUID
/etc/machine-id
SSH host keys
TPM sealed object
随机种子
```

要求的是：

```text
拓扑一致
标签一致
行为一致
```

不要求 UUID 一致。

## 5.3 需要 secret 恢复的内容

包括：

```text
age identity
SSH 私钥
用户密码材料
Mihomo 订阅配置
API secret
备份密钥
Secure Boot 私钥
LUKS 恢复密钥
TPM enrollment 材料
```

## 5.4 需要备份恢复的数据

包括：

```text
项目源码
文档
照片
视频
邮件
浏览器数据
应用数据库
聊天记录
游戏存档
用户生成内容
```

完整恢复公式：

```text
可重建机器
=
guix-configs
+ 锁定频道
+ host 硬件事实
+ secrets
+ 用户数据备份
```

---

# 32. 主仓库目录结构

```text
~/guix-configs/
├── README.md
├── channels.scm
├── channels.lock.scm
│
├── manifests/
│   ├── installer.scm
│   └── development.scm
│
├── modules/
│   └── guixcfg/
│       ├── hosts/
│       │   ├── vm.scm
│       │   └── laptop.scm
│       │
│       ├── storage/
│       │   ├── model.scm
│       │   ├── plan.scm
│       │   ├── validate.scm
│       │   ├── device.scm
│       │   ├── partition.scm
│       │   ├── filesystem.scm
│       │   ├── subvolume.scm
│       │   ├── install.scm
│       │   └── root-generation.scm
│       │
│       ├── system/
│       │   ├── common.scm
│       │   ├── packages.scm
│       │   ├── file-systems.scm
│       │   ├── hardware/
│       │   │   ├── graphics.scm
│       │   │   └── printing.scm
│       │   └── profiles/
│       │       ├── desktop.scm
│       │       ├── development.scm
│       │       └── gaming.scm
│       │
│       ├── services/
│       │   ├── persistence.scm
│       │   ├── ephemeral-root.scm
│       │   ├── age-secrets.scm
│       │   ├── mihomo.scm
│       │   └── backup.scm
│       │
│       ├── boot/
│       │   ├── uki.scm
│       │   ├── limine.scm
│       │   ├── secure-boot.scm
│       │   └── tpm.scm
│       │
│       └── home/
│           ├── common.scm
│           ├── packages.scm
│           ├── desktop.scm
│           ├── services/
│           │   ├── files.scm
│           │   ├── environment.scm
│           │   └── flatpak.scm
│           └── profiles/
│               ├── base.scm
│               ├── desktop.scm
│               └── development.scm
│
├── tools/
│   ├── disk-install.scm
│   └── test-vm.sh
│
├── tests/
│   ├── test-model.scm
│   ├── test-plan.scm
│   ├── test-validate.scm
│   ├── test-device.scm
│   ├── test-modules-load.scm
│   └── run-tests.scm
│
├── files/
│   ├── niri/
│   └── ...
│
├── secrets/
│   ├── hosts/
│   │   ├── vm/
│   │   └── laptop/
│   └── recipients/
│
└── docs/
    ├── project-definition.md
    ├── deployment.md
    ├── storage.md
    ├── secrets.md
    ├── boot.md
    ├── system.md
    └── installation.md
```

`modules/` 的模块命名：

```text
modules/guixcfg/storage/model.scm
    → (guixcfg storage model)

modules/guixcfg/hosts/laptop.scm
    → (guixcfg hosts laptop)
```

通过：

```text
-L modules
```

加入 Guile load path。

---

# 35. 开发顺序

## 阶段一：存储纯模型

完成：

```text
storage/model.scm
storage/plan.scm
storage/validate.scm
```

只打印计划，不操作磁盘。

## 阶段二：VM 磁盘安装

完成：

```text
device.scm
partition.scm
filesystem.scm
subvolume.scm
install.scm
disk-install.scm
```

目标：

```text
空 qcow2
→ GPT
→ ESP
→ LUKS2
→ Btrfs
→ 全部 @persist-* 子卷
→ swapfile
→ /mnt
```

## 阶段三：VM Guix System

完成：

```text
system/common.scm
system/file-systems.scm
hosts/vm.scm
```

目标：

```text
空磁盘
→ Guix System
→ 可启动
```

## 阶段四：Root generation

完成：

```text
root-generation.scm
ephemeral-root.scm
```

目标：

```text
@root-installing
→ @root-template
→ @root-0
→ @root-N
```

## 阶段五：UKI、Limine、Secure Boot

完成：

```text
uki.scm
limine.scm
secure-boot.scm
tpm.scm
```

全部先在 VM 验证。

## 阶段六：Laptop

增加真实硬件配置：

```text
system/hardware/graphics.scm
system/hardware/printing.scm
```

包括 Intel + NVIDIA 混合显卡、PRIME、`foo2zjs` 打印机和 udev 规则，全部实机验证。

## 阶段七：Guix Home 与桌面

实现：

```text
niri
Noctalia
fcitx5
用户包
公开配置
Flatpak
```

## 阶段八：Secret、Mihomo 和备份

实现：

```text
age 整文件秘密
/run/secrets
Mihomo
mihomo-remote
backup service
```

---

# 36. 最终设计原则

1. 固定架构直接写进算法，不伪装成通用配置。

2. 所有长期状态 Btrfs 子卷都必须使用 `@persist-` 前缀。

3. 除标准 `/gnu/store` 和 `/var/guix` 外，持久化顶级挂载点统一位于 `/persist`。

4. Root generation 使用 `@root-*`，因为它不是长期状态目录。

5. Host 是最终 `<operating-system>` 的组装点。

6. 共享模块不反向依赖 host。

7. 配置工作区不是正常启动依赖。

8. 公开配置进入 `/gnu/store`。

9. age 密文进入 Git 和 store，明文只进入 `/run`。

10. 机器 identity 位于 `/persist/system`。

11. 可变应用状态位于 `/persist/data-app`。

12. 普通用户数据位于 `/persist/data-home`。

13. 不备份的大型状态位于 `/persist/data-nobackup`。

14. 不把配置仓库直接软链接到应用运行路径。

15. 不在开机时复制一份仓库配置到持久目录。

16. 正式部署只消费已提交 Git commit 的只读快照。

17. 频道更新和系统部署严格分离。

18. Flatpak 是用户桌面层，不是仓库根级软件子系统。

19. Flatpak 默认只补齐，不自动删除。

20. Rust 多版本由项目 manifest 和频道锁管理，不使用 rustup。

21. `configctl` 是独立 Rust 部署工具，不解析 Scheme。

22. `mihomo-remote` 是独立 Rust 控制工具。

23. 先完成 VM，再适配 Laptop。

24. 在真实重复出现之后再进行抽象。

25. 少量明确重复优于维护一个自制的 NixOS module system。

26. 配置仓库随用户数据持久化，不单独拆分子卷。

27. 驱动通过 kernel、firmware、module 和 service 声明进入 system generation，不使用独立安装器。

28. 打印机队列声明式创建，不持久化 CUPS 命令式状态。

29. 自定义 record 使用 `(guix records)` 的 `define-record-type*`（具名字段、`default`、`inherit`），不使用裸 SRFI-9。
