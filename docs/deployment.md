# 部署模型与日常工作流


---

# 6. 滚动且稳定

系统采用“滚动但稳定”的模型。

## 6.1 滚动

允许持续更新：

```text
Guix channel
Nonguix
personal-channel
其他外部 channel
Flatpak 应用
系统软件
用户软件
```

频道和应用版本不会永久冻结在初始安装版本。

## 6.2 稳定

任何正式部署只能消费：

```text
已经提交的 Git commit
已经锁定的 channel revisions
只读配置快照
```

正式部署禁止直接消费可编辑工作区。

## 6.3 脏工作区规则

允许脏工作区的操作：

```text
configctl check
configctl system build
configctl home build
configctl disk inspect
configctl disk plan
```

这些操作用于开发和验证。

拒绝脏工作区的操作：

```text
configctl system switch
configctl home switch
configctl install
configctl disk apply
任何正式部署操作
```

以下任意状态都算脏：

```text
已修改未提交文件
已暂存未提交文件
未跟踪文件
Git 冲突
```

正式部署不提供 `--allow-dirty`。

## 6.4 部署快照

`configctl` 在部署前：

```text
1. 检查工作区干净
2. 读取 HEAD commit
3. 使用 git archive 导出 HEAD
4. 创建只读临时快照
5. 让 Guix 消费该快照
6. 完成后删除快照
```

不能在检查完干净后，继续直接消费可被修改的 checkout。

## 6.5 部署记录

当前系统应生成：

```text
/etc/guix-configs/host
/etc/guix-configs/revision
```

示例：

```text
host:
laptop

revision:
9ba2f1...
```

还可以记录锁定频道 revision 的摘要。

这些文件是当前 system generation 的产物，不需要放入持久数据目录。

---

# 7. 频道管理

主仓库包含：

```text
channels.scm
channels.lock.scm
```

## 7.1 `channels.scm`

描述频道集合和上游来源。

预计包括：

```text
Guix
Nonguix
personal-channel
Bluebox（过渡期需要时）
Rosenthal（确实需要其 boot package 时）
```

不需要的频道应删除，不为“以后可能用”永久保留。

注：Guix 官方 Git 仓库已迁移，`https://git.guix.gnu.org/guix.git` 重定向到 `https://codeberg.org/guix/guix.git`，`channels.scm` 使用 Codeberg 直连。

## 7.2 `channels.lock.scm`

固定实际使用的：

```text
channel commit
channel introduction
channel branch
```

所有构建和部署均通过：

```text
guix time-machine -C channels.lock.scm
```

运行。

## 7.3 频道镜像与 substitutes 分离

必须区分：

```text
Git channel URL
    获取 Guix channel 源码

substitute URL
    下载预构建 store item
```

两者配置分开。

项目需要支持：

- 为各 channel 单独配置镜像；
- 为 Guix substitutes 配置 mirror list；
- LiveCD 环境使用代理；
- 安装器、构建器和部署器统一使用这些配置。

## 7.4 更新过程

频道更新必须显式执行：

```text
更新 channel lock
→ 构建
→ 检查
→ 提交
→ switch
```

`system switch` 和 `home switch` 不能隐式更新频道。

---

# 8. 主仓库位置

用户可见路径：

```text
~/guix-configs
```

实际持久化后端：

```text
/persist/data-home/<user>/guix-configs
```

再通过 bind mount 或等价的持久映射暴露为：

```text
/home/<user>/guix-configs
```

仓库要求：

- 由普通用户拥有；
- 保留完整 `.git`；
- 纳入源码备份；
- 位于持久化存储中；
- 不放入 `/etc`；
- 不放入 `/gnu/store`；
- 不放入 `/var/guix`；
- 不由 root 日常编辑。

Git 远端是长期源码副本。

本地 `~/guix-configs` 是当前机器的可编辑 checkout。

## 8.1 不单独拆分子卷

配置仓库不创建独立的：

```text
@persist-guix-configs
```

它继续位于：

```text
@persist-data-home
└── <user>/
    └── guix-configs/
```

运行时映射为：

```text
/persist/data-home/<user>/guix-configs
    → /home/<user>/guix-configs
```

即用户可见的 `~/guix-configs`。

原因：

- 配置仓库体积很小；
- 与其他项目源码采用相同备份策略；
- 已有 Git 远端作为额外副本；
- 不需要单独配额、压缩参数或挂载选项；
- 没有独立于用户数据进行 Btrfs 快照、恢复或 `send/receive` 的强需求。

单独子卷会额外增加：

- 安装器的子卷与挂载规则；
- Home 持久化映射；
- 快照和备份边界；
- 恢复时的挂载顺序；
- “仓库存在，但用户数据子卷没有挂载”之类的额外状态。

只有以后明确需要让配置仓库拥有独立的：

```text
快照周期
备份目的地
保留期限
只读复制
Btrfs send/receive
```

才值得拆成：

```text
@persist-guix-configs
    → /persist/guix-configs
    → ~/guix-configs
```

目前不拆。

---

# 9. 仓库与运行系统的关系

关系为：

```text
~/guix-configs
    配置源码
          ↓ build / reconfigure

/gnu/store
    不可变配置与程序产物
          ↓ profile activation

/var/guix/profiles/system
    Guix system generations
```

当前系统正常启动：

- 不依赖 `~/guix-configs` checkout；
- 不依赖 Git；
- 不依赖网络；
- 不依赖 `configctl`。

当前系统依赖：

- 当前 system generation；
- `/gnu/store` 中已部署的程序和配置；
- `/var/guix` 中的 profiles；
- `/persist` 中的机器身份和可变状态；
- `/run` 中启动时生成的临时 secret 和配置。

任何运行时链接都禁止直接指向：

```text
~/guix-configs
```

运行时链接只能指向：

```text
/gnu/store
/run
/persist
```

---

# 29. `configctl`

## 29.1 安装方式

`configctl` 由 personal-channel 打包，并安装为系统级工具：

```text
/gnu/store/...-configctl/bin/configctl
```

用户可以从任意目录执行。

## 29.2 默认仓库

默认：

```text
~/guix-configs
```

允许显式覆盖：

```text
GUIX_CONFIGS_REPO=/path/to/repo
```

路径必须在 sudo 前解析为绝对路径。

## 29.3 当前 host

读取：

```text
/etc/guix-configs/host
```

安装环境中必须显式传入：

```text
--host vm
--host laptop
```

## 29.4 主要命令

```text
configctl check

configctl system build
configctl system switch

configctl home build
configctl home switch

configctl channels show
configctl channels refresh

configctl disk inspect
configctl disk plan
configctl disk apply

configctl install
```

Flatpak 初期不设为顶层控制域，由 Guix Home service 管理。

## 29.5 权限

普通用户负责：

```text
编辑
Git 操作
构建
检查
```

只有实际系统部署、磁盘操作和安装阶段提升权限。

不能要求用户以 root 身份日常管理仓库。

## 29.6 禁止行为

`configctl` 不应：

```text
自动 git pull
自动 clone 丢失的仓库
自动更新 channel
自动部署脏工作区
后台监控文件变化
开机自动 reconfigure
自动删除 Flatpak 应用
自动选择可破坏磁盘
```

---

# 33. 日常工作流

## 33.1 安装普通用户软件

修改：

```text
modules/guixcfg/home/packages.scm
```

流程：

```text
修改
→ configctl home build
→ git diff
→ git commit
→ configctl home switch
```

不使用临时 `guix install` 作为长期状态。

## 33.2 安装系统软件

修改：

```text
modules/guixcfg/system/packages.scm
```

流程：

```text
修改
→ configctl system build
→ git commit
→ configctl system switch
```

## 33.3 安装 Flatpak 应用

修改：

```text
modules/guixcfg/home/profiles/desktop.scm
```

流程：

```text
修改 Flatpak 应用声明
→ configctl home build
→ git commit
→ configctl home switch
```

Home service 安装缺失应用，不自动删除额外应用。

## 33.4 编译 Rust 项目

项目已有环境：

```bash
guix time-machine \
  -C channels.lock.scm \
  -- shell \
  -m manifest.scm \
  -- cargo build
```

项目没有环境：

```bash
guix shell rust pkg-config gcc-toolchain \
  -- cargo build
```

长期使用时，为项目创建自己的：

```text
manifest.scm
channels.lock.scm
```

## 33.5 修改 niri

修改：

```text
files/niri/config.kdl
```

流程：

```text
configctl home build
→ git commit
→ configctl home switch
```

部署后 niri 读取 store 中的配置，不读取 Git checkout。
