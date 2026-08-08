# 存储模型


---

# 10. 持久化命名规则

## 10.1 所有持久子卷必须有前缀

所有承载长期状态的 Btrfs 子卷统一使用：

```text
@persist-
```

前缀。

禁止出现：

```text
@store
@guix
@home
@snapshots
@swap
```

这类没有持久化前缀的长期状态子卷。

## 10.2 所有持久化顶级目录必须位于 `/persist`

除必须使用标准路径的：

```text
/gnu/store
/var/guix
```

外，所有持久化挂载点均位于：

```text
/persist/...
```

`/gnu/store` 和 `/var/guix` 虽然挂载点不在 `/persist`，其背后的子卷名仍必须带 `@persist-` 前缀。

## 10.3 Root 子卷不是持久状态目录

以下子卷不使用 `@persist-`：

```text
@root-installing
@root-template
@root-0
@root-1
...
```

原因是它们是可替换的 root generation，不是长期状态数据。

---

# 11. 磁盘布局

固定物理布局：

```text
GPT
├── EFI System Partition
│   ├── VFAT
│   ├── 挂载到 /efi
│   └── 保存 Limine、UKI 和启动文件
│
└── Encrypted System Partition
    ├── LUKS2
    ├── mapper: cryptroot
    └── Btrfs
```

不创建：

```text
独立 /boot 分区
独立 swap 分区
独立 /home 分区
恢复分区
```

ESP 大小由 host policy 提供，目标范围：

```text
2–4 GiB
```

剩余磁盘全部进入 LUKS2。

Swap 使用 Btrfs swapfile。

---

# 12. 固定持久子卷

Btrfs 中创建：

```text
@persist-gnu-store
@persist-var-guix
@persist-system
@persist-data-app
@persist-data-home
@persist-data-nobackup
@persist-swap
@persist-snapshots
```

对应挂载：

```text
@persist-gnu-store
    → /gnu/store

@persist-var-guix
    → /var/guix

@persist-system
    → /persist/system

@persist-data-app
    → /persist/data-app

@persist-data-home
    → /persist/data-home

@persist-data-nobackup
    → /persist/data-nobackup

@persist-swap
    → /persist/swap

@persist-snapshots
    → /persist/snapshots
```

这些子卷名称是固定项目事实，不是每台机器都能随意修改的字段。

---

# 13. 各持久区域职责

## 13.1 `/persist/system`

保存机器级身份和系统状态：

```text
/persist/system/
├── keys/
│   ├── age/
│   │   └── host.key
│   └── secure-boot/
├── ssh/
├── machine-id
├── facts/
├── install/
└── root-generations/
```

包括：

- age identity；
- Secure Boot 密钥；
- SSH host keys；
- machine-id；
- 安装时发现的机器事实；
- root generation 状态；
- 安装 revision；
- 必要的 TPM enrollment 状态。

## 13.2 `/persist/data-app`

保存需要备份的可变应用状态：

```text
/persist/data-app/
├── browser/
├── mail/
├── mihomo/
├── flatpak/
└── ...
```

具体应用可以拆成独立目录。

## 13.3 `/persist/data-home`

保存用户正常数据：

```text
/persist/data-home/<user>/
├── guix-configs/
├── Documents/
├── Desktop/
├── Pictures/
├── Videos/
└── Projects/
```

最终选择哪些普通目录持久化，由 Home/persistence 配置明确声明。

不要求整个 `$HOME` 全部持久化。

## 13.4 `/persist/data-nobackup`

保存需要持久，但不进入常规备份的数据：

```text
Steam 游戏文件
可重新下载的大型资源
构建缓存
部分模型文件
大型临时资产
```

## 13.5 `/persist/swap`

保存：

```text
/persist/swap/swapfile
```

Btrfs swapfile 必须满足：

- NOCOW（`chattr +C`，或创建时使用 `btrfs filesystem mkswapfile`）；
- 不压缩；
- 预分配，不做快照；
- 不放入任何会被快照的子卷。

`@persist-swap` 专用于隔离这些约束，swapfile 不进入快照和备份。

## 13.6 `/persist/snapshots`

保存本地快照和恢复快照。

本地 snapshot 不能替代异机备份。

---

# 17. Root generation

## 17.1 命名

```text
@root-installing
@root-template
@root-N
@root-N.new
```

编号不补零：

```text
@root-0
@root-1
@root-2
```

时间戳只作为 metadata，不作为 generation identity。

## 17.2 安装阶段

创建：

```text
@root-installing
```

挂载到：

```text
/mnt
```

再挂载全部持久子卷和 ESP。

执行系统安装。

## 17.3 安装完成

从 `@root-installing` 创建：

```text
只读 @root-template.new
可写 @root-0.new
```

验证成功后事务性提交为：

```text
@root-template
@root-0
```

最后删除：

```text
@root-installing
```

## 17.4 首次启动

首次启动：

```text
@root-0
```

健康检查通过后：

```text
current = 0
last-good = 0
```

## 17.5 后续正常启动

从模板创建：

```text
@root-N.new
```

完成准备后提交：

```text
@root-N
```

再启动该 generation。

## 17.6 启动模式

至少提供：

```text
Normal
Keep
Recovery
```

行为：

```text
Normal
    创建新的 root generation

Keep
    继续使用指定 root generation，不创建新 generation

Recovery
    启动已知可用 generation 或恢复环境
```

## 17.7 状态位置

```text
/persist/system/root-generations/
```

至少保存：

```text
next-generation
current-generation
last-good-generation
created-at
boot-status
source-template
system-revision
```

## 17.8 清理

根据 host policy 保留一定数量的旧 root generations。

不能删除：

- 当前 generation；
- last-good；
- recovery 所引用 generation；
- 正在事务性创建的 generation。

---

# 18. 两种 generation

必须区分：

## 18.1 Guix system generation

管理：

```text
内核
服务
软件包
系统配置
启动产物
```

位置：

```text
/var/guix/profiles/system
```

## 18.2 Btrfs root generation

管理：

```text
某次启动使用的可写根目录
```

名称：

```text
@root-N
```

## 18.3 Git commit

管理：

```text
系统期望状态源码
```

关系：

```text
Git commit
    ↓
Guix system generation
    ↓
UKI / system closure
    ↓
在某个 @root-N 中启动
```

---

# 19. 动态机器事实

运行时发现的内容不能硬编码进静态 host 模块：

```text
实际 UUID
实际 PARTUUID
格式化后生成的文件系统 ID
当前 root generation
last-good generation
实际设备节点
```

优先使用固定语义名称：

```text
PARTLABEL
filesystem label
LUKS label
mapper name
```

无法避免时，安装器生成机器事实文件：

```text
/persist/system/facts/host.scm
```

`configctl` 在构建当前机器时显式传入：

```text
GUIX_CONFIG_FACTS=/persist/system/facts/host.scm
```

在 `configctl` 可用之前，配置在构建期依次读取 `GUIX_CONFIG_FACTS` 环境变量和上述固定路径，文件不存在时回退到语义名称。LiveCD 安装期间目标系统的 facts 位于 `/mnt/persist/...`，因此安装时必须带上环境变量，例如 `GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm guix system init ...`。

已实证的例外：**initrd 里没有 udev**（Guix initrd 手工 mknod 设备节点，不运行 udevd），因此 `/dev/disk/by-partlabel/` 等符号链接在 initrd 阶段不存在。mapped-device 的 source 是字符串路径时 initrd 原样使用、不等待不解析，必然失败；source 是 LUKS UUID 时 initrd 会扫描块设备匹配 LUKS 头（`find-partition-by-luks-uuid`，带重试），无需 udev。因此 LUKS mapped-device 的 source **必须**使用 facts 中的 `luks-uuid`，不能只用 PARTLABEL。by-partlabel 仅在完整系统（有 udev）中可用，例如 ESP 的 file-system 声明。

该文件：

- 不进入 Git；
- 可以重新探测生成；
- 由安装器维护；
- 不承载通用配置策略。

---

# 20. 存储模型边界

## 20.1 固定事实

直接写入实现：

```text
GPT
ESP
LUKS2
Btrfs
固定 PARTLABEL
固定 mapper 名
固定持久子卷集合
固定 root generation 命名
```

## 20.2 Host policy

真正因机器而不同的内容：

```text
ESP 大小
最低磁盘容量
swapfile 大小
保留 root generation 数量
预期物理磁盘 by-id
部分挂载策略
```

## 20.3 非目标

不实现：

```text
任意磁盘树
任意 RAID 组合
任意文件系统节点
通用 storage DSL
任意多盘安装框架
```

---

# 31. 存储安装器安全要求

破坏性操作必须：

- 显式传入 host；
- 显式传入整块设备；
- 拒绝分区设备；
- 解析并显示 by-id（无 by-id 时退到 by-path。注意：virtio 盘的 by-id 要求 QEMU 侧配置磁盘 serial；eudev 的 path_id 不支持 virtio，by-path 对 virtio 盘不可用）；
- 拒绝已挂载设备；
- 拒绝当前系统盘；
- 拒绝 LiveCD 介质；
- 检查容量；
- 打印操作计划；
- 输入完整路径确认；
- 支持 dry-run/plan；
- 等待 udev 分区节点出现；
- 每一步失败立即停止；
- 不自动继续半完成操作。

初始只支持：

```text
fresh
```

即全盘重建模式。

暂不实现复杂的保留分区或原地迁移。

---

# 34. 备份要求

必须备份：

```text
/persist/data-home
/persist/data-app 中的重要应用数据
/persist/system/keys 的离线安全副本
/persist/system/ssh
必要的机器身份和恢复信息
Git 远端中的 guix-configs
```

默认不备份：

```text
/persist/data-nobackup
/persist/swap
可重新下载的大型文件
普通缓存
```

`/gnu/store` 和 `/var/guix` 可由配置重建，不是用户数据备份的核心对象。

Secure Boot、age 和 LUKS 恢复材料必须另外保存在离线介质。

本地 `/persist/snapshots` 不能替代远程或离线备份。
