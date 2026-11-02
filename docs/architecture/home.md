# Home Architecture

Guix Home 与用户数据边界。

## System / Home / Persistent data 三层边界

- **Guix System owns**：machine users/groups、`/etc/passwd` login
  shell、filesystem/mount topology、user persistence mappings、
  sshd/SSH policy/host keys、system services、boot/security。
- **Guix Home owns**：user packages、shell rc/config、aliases、
  environment、Git config、dotfiles、user services。
- **Persistent data layer owns**：user-created persistent data、SSH
  host private keys、application state / private secrets。

Home 不挂载 /persist、不管理 sshd、不创建 private keys；System 不
重建用户数据。

## Application layer（纵向配置单元）

用户态/application-level 组件以**应用为纵向单元**组织（AGENT.md
§Application layer）：

```text
modules/guixcfg/apps/
├── model.scm                <application> record（contribution container）
├── registry.scm             显式启用列表（%applications；目录存在 != 启用）
└── <app>/
    ├── definition.scm       声明入口（(guixcfg apps <app> definition)）
    ├── 公开配置 colocate    如 config.kdl
    └── secrets/*.age        单一 app owner 的加密密文
```

`<application>` 只声明 contributions（home-packages / home-services /
system-services / persistence / secrets）；部署由各自的 generic
single-owner mechanism 执行：

- home packages/services → Guix Home（applications-home-* 聚合进
  `%guix-home`）；
- persistence rules → `(guixcfg system application-persistence)`
  （/persist/data-app bind，见 persistence.md）；
- secrets → `(guixcfg security secrets)` publisher（ciphertext
  file-like 由 app definition 解析；见 secrets.md）。

**Configuration variant selection**：application 声明可选配置变体
（资源 colocate 在应用目录）；host/profile 层只做 logical
selection（`(guixcfg apps selection)`：application 名 + variant 名，
不知道文件/路径）。`guix-home` 接受
`#:application-configuration-selections` 参数；默认 `%guix-home`
（无特殊 selection）供组装点直接使用。依赖方向
application ← host（application 不读取 host；详见 applications.md
（Host-agnostic boundary））。

**Flatpak driver adapter**：`guix-home` 还接受
`#:flatpak-environment-overrides` 参数（host 的硬件驱动 adapter：
logical app name → `VAR=VALUE` 环境条目列表，如 NVIDIA PRIME）——
全局 Flatpak selection 跨设备一致，差异只经该 overlay 叠加到
managed override；见 flatpak.md（Global selection 与 host driver
adapter）。

不实现 NixOS/RDE module framework（无 solver/priority/override/
自动发现）。新增应用：`cp -r templates/application
modules/guixcfg/apps/foo` → 填 definition → registry 加一行。

**完整契约与教程**：`docs/architecture/applications.md`（架构参考：
contract、layout、local-file 语义、ownership 决策表、secret/
数据归属、runtime 不变量）与 `docs/development/applications.md`
（逐步新增应用教程 E1-E9）。

## Ephemeral /home + bind-mounted 用户数据

`/home/<user>` 本身是 ephemeral（无状态 root）。持久化用户数据由
系统从 `/persist/data-home/<user>/` bind mount
（`%persistent-user-dirs`，modules/guixcfg/system/user-persistence.scm）
——标准 XDG user directories 全集：

```text
Projects / Desktop / Documents / Downloads /
Music / Pictures / Public / Templates / Videos
```

仓库 checkout 位于 `Projects/guix-configs`，是 `Projects` backing 中的
普通项目目录；不声明仓库专属 bind mount，也不声明嵌套 bind mount。

每个条目是 `(backing, consumer)` 相对路径对：backing 位于
`/persist/data-home/<user>/` 下（canonical 数据位置），consumer 是
`$HOME` 下的挂载位置（可嵌套）。嵌套 consumer 的 HOME 侧中间父目录
owner 归还走共享原语 `(guixcfg utils home-path)`（AGENT.md §12）。

XDG user directories 由 Guix Home 声明（官方
`home-xdg-user-directories-service-type`，`(guixcfg home xdg)` 的
`%xdg-user-dirs-service`）：生成 `~/.config/user-dirs.dirs` 并在
activation 创建各目录；持久化 backing 与声明的一致性由
tests/test-user-persistence.scm 回归。

### Trash 语义（GLib 2.86 实证，2026-08）

- **home trash（`$XDG_DATA_HOME/Trash`）不持久化**：GLib 的
  `g_local_file_trash` 按 st_dev 把普通 HOME 文件判为 home trash；
  若该目录是独立 bind mount，rename 跨 mount → EXDEV，所有普通
  文件删除失败（实测复现）。home trash 随 ephemeral /home 每 boot
  重建——符合无状态系统语义（重启前可恢复）。
- **persistent mount 内文件（Documents 等）**：st_dev 与 home 不同
  → freedesktop mount-local trash（该挂载根部的 `.Trash-$uid`，
  同 mount rename，随 persistent storage 存活）；GVfs 的
  `trash:///` 统一聚合展示。
- **桌面集成 metadata**：HOME persistence bind mounts 带
  `x-gvfs-hide,x-gvfs-trash`（共享常量
  `%persistent-home-mount-options`，authority 是
  `(guixcfg system mount-metadata)`——不是 `utils/home-path`，后者
  只做 pathname/ownership 原语）：
  - bind mount 经 mount(2) 挂载时 x-* 不进 mountinfo，GIO 的 fstab
    fallback 对 bind 条目不可达——`(guixcfg system mount-metadata)`
    的 one-shot 服务在 file-systems 后就位后把
    `SRC/TARGET/ROOT/OPTS` 条目幂等写入 `/run/mount/utab`（libmount
    解析 mountinfo 时合并 utab 的 user options——merge_user_fs 要求
    SRC/TARGET/ROOT 三者都与 mountinfo 匹配才合并，GIO 由此看到
    x-gvfs-*）；
  - **ownership marker**：utab 条目的 OPTS 附带
    `x-guixcfg.home-persistence`（`(guixcfg utils mountinfo)` 的
    `%guixcfg-utab-ownership-marker`）——desktop 语义
    （x-gvfs-hide/x-gvfs-trash）与 ownership 分离。服务只重建带
    marker 的条目；其它 owner 即使用相同桌面选项也保留；marker 在
    `/run`（tmpfs）中随 reboot 自然重置（旧格式条目无需迁移逻辑）；
  - **live reconfigure lifecycle**：本 one-shot 在每次
    `guix system reconfigure` 的 upgrade-shepherd-services 落入
    to-start（pinned guix 源码证实：已完成 one-shot 的 running 值
    为 #f、auto-start? 默认 #t）——persistence declaration 增删 /
    backing 变化在同一轮 reconfigure 后自动重跑，从当前
    `/proc/self/mountinfo` 重建条目，无需 reboot 或显式 restart；
  - `x-gvfs-hide`：不作为独立挂载/卷出现在文件管理器侧边栏；
  - `x-gvfs-trash`：允许该 mount 的 trash（bind mount 默认被 GLib
    判为 system internal，trash 被拒）；
  - machine-state persistence（/etc、/var 等）不带这些 options
    （不是桌面用户 trash domain）。

显式 ephemeral（除精确声明的 `~/.cache/guix` 外）：`~/.cache`、`~/.config`、`~/.local`
（含 Trash）、`~/.mozilla`、`~/.steam`、整个 HOME。本轮不声称完整用户
状态持久化。**应用级 mutable state**（如未来 Firefox profile）走
`/persist/data-app` bind（application-persistence 规则，不整目录持久化；
见 persistence.md）。

## Guix Home 是 derived state

`/home/<user>` 是 ephemeral；Guix Home 管理的一切都是 **derived
state**，由仓库 + 当前 system generation 重新生成——不持久化：

- `~/.guix-home` 与 dotfile symlinks 不属于 persistence inventory；
  每次 boot 由官方 `guix-home-service-type` 重新创建。

机制（官方 Guix 机制，无自定义重实现）：

- `home-environment`（`(guixcfg home user)` 的 `%guix-home`）经
  `(service guix-home-service-type ...)` 挂入 operating system，
  在 `guix system reconfigure` 时构建，成为 **system generation
  closure** 的一部分；
- `%guix-home` 是薄 assembly：packages/services 全部来自
  `%applications`（registry）的 aggregation，本文件不知道具体
  应用配置；
- boot 时 one-shot shepherd 服务 `guix-home-user`（requirement
  `(user-processes)`）以 user 身份运行 closure 的 activate 脚本；
  symlink manager 原子重建 `~/.guix-home`（symlink + rename）与
  dotfile symlinks；
- boot 不运行 `guix home reconfigure`：无新 home generation、无
  re-evaluation、无 derivation 工作；
- activate 脚本从自身 store path 推导目标 home
  （`dirname (car (command-line))`）——boot system generation N 激活
  恰好绑定 N 的 home；rollback / Last Good / Recovery 按 system
  generation 构造性地跟随，而非 mutable record。

## Home closure 属于 system generation

没有独立的 Home generation 轴。Home 绑定随 system generation 切换。

## 为什么不做独立 Home generation（决策记录）

结论：Home 部署保持绑定 system generation；**不引入独立的 Home
generation 轴**，也不把 `guix-home-service-type` 换成用户侧
`guix home reconfigure` 的持久部署。

理由（按不变量优先级）：

1. `/home/<user>` 是 ephemeral。独立 Home generation 的
   `~/.guix-home` 在重启后不存在；要跨 boot 保留，只能把 Home
   generation（或其 symlink）放进 persistence，并另加 boot 激活
   服务。这会把 derived state 变成第二套 mutable authority，违反
   persistent/derived 边界。
2. `home-ready` 是 `interactive-session-ready` 的 prerequisite，
   直接控制 login gate。独立部署时 gate 只能二选一：不等 Home
   （登录到半成品 HOME），或等待一个不由 system generation 固定
   的 mutable 状态（race，无法 fail-closed 验证）。
3. rollback / Last Good / Recovery 是单轴：system generation 回滚
   必须带回匹配的 Home。独立轴需要额外的配对与兼容矩阵，且
   Recovery 可能 boot 出 old system + new Home。
4. Home 服务与 system 侧事实耦合：accounts、PAM/elogind、runtime
   secrets（如 gnome-keyring master）、persistence mount topology、
   desktop wrapper。两套 generation 会形成版本 skew；secrets 的
   ordinary/login-critical 分区也失去“同代发布”的保证。
5. `guix-home-service-type` 是 pinned Guix 的官方机制，语义正好是
   “system + home 一致地一次部署”；自定义第二轴只在语义确实不同
   时才允许（AGENT.md §7）。

### 允许的瞬态快测（不是持久部署）

上游支持用 `guix home reconfigure` 操作嵌入的 Home，但效果
**不超过下一次 system activation**（pinned `guix.texi`
“guix-home-service-type”）。本仓库只在开发/验证时使用：

```sh
env GUILE_LOAD_PATH="$PWD/modules" \
    GUILE_LOAD_COMPILED_PATH="$PWD/modules" \
  guix time-machine -C channels.lock.scm -- \
  home reconfigure --dry-run modules/guixcfg/hosts/<host>.scm
```

- 先跑 `--dry-run`；确认后去掉它。
- 必须用 host 入口（如 `hosts/lenovo-legion-y7000p.scm`）：
  `home/user.scm` 的 `%guix-home` 不含 host 的 application
  selection / NVIDIA / Flatpak overrides。
- 它会切换当前 `~/.guix-home`，可能重启 Home Shepherd 服务；
  不经过 login gate，也不提供 readiness 验证。
- 下一次 `blue reconfigure` 或 reboot 由 system generation 覆盖
  回权威 Home；**禁止**把它当作持久变更路径。

### 可选的绑定内优化

Home-only 改动不改变 kernel/initrd/cmdline/os-release，UKI 内容
相同；当前 `boot/uki.scm` 仍在每次 reconfigure 重建非活动槽。
若部署 churn 成为问题，可在绑定内比较内容并跳过未变化的槽重写，
而不是拆 generation 轴。

### 重新评估的条件

- `/home` 变为持久（不再 ephemeral）；
- 多用户需要各自独立的 Home 部署/回滚；
- home-only 变更频率/耗时成为主要瓶颈，且瞬态路径不够；
- 需要独立 Home rollback 轴。

届时使用上游 Home generation，并显式设计 system/home 配对与
兼容检查；不要 ad hoc 移除 `guix-home-service-type`。

## Live reconfigure vs cold boot

- cold boot：`guix-home-user` one-shot 重建链接；
- live reconfigure：`(guixcfg system reconfigure)` 事务（经
  `blue reconfigure HOST`）在 system reconfigure 后显式 restart
  `guix-home-user` 并轮询验证链接指向 store（失败则 gate 保持
  关闭）。stale pivot（`~/.guix-home.new`）由 `(guixcfg home
  pivot)` 直接 Scheme 调用保守清理（只 unlink 指向 store home
  generation 的 symlink；针对 pinned Guix symlink-manager 的
  stale pivot gap 的 narrow compatibility shim）。
