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
（无特殊 selection）供 VM 等组装点直接使用。依赖方向
application ← host（application 不读取 host；详见 applications.md
（Host-agnostic boundary））。

不实现 NixOS/RDE module framework（无 solver/priority/override/
自动发现）。新增应用：`cp -r templates/application
modules/guixcfg/apps/foo` → 填 definition → registry 加一行。

**完整契约与教程**：`docs/architecture/applications.md`（架构参考：
contract、layout、local-file 语义、ownership 决策表、secret/
数据归属、runtime 不变量）与 `docs/development/applications.md`
（逐步新增应用教程 E1-E9）。

## Ephemeral /home + bind-mounted 用户目录

`/home/<user>` 本身是 ephemeral（无状态 root）。持久目录由系统
从 `/persist/data-home/<user>/` bind mount（`%persistent-user-dirs`，
modules/guixcfg/system/user-persistence.scm）——标准 XDG user
directories 全集 + 仓库 checkout：

```text
guix-configs / Projects / Desktop / Documents / Downloads /
Music / Pictures / Public / Templates / Videos
```

XDG user directories 由 Guix Home 声明（官方
`home-xdg-user-directories-service-type`，`(guixcfg home xdg)` 的
`%xdg-user-dirs-service`）：生成 `~/.config/user-dirs.dirs` 并在
activation 创建各目录；持久化 backing 与声明的一致性由
tests/test-user-persistence.scm 回归。

显式 ephemeral（本轮不持久化）：`~/.cache`、`~/.config`、
`~/.local`、`~/.mozilla`、`~/.steam`、整个 HOME。本轮不声称完整
用户状态持久化。**应用级 mutable state**（如未来 Firefox profile）
走 `/persist/data-app` bind（application-persistence 规则，不整目录
持久化；见 persistence.md）。

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

## Live reconfigure vs cold boot

- cold boot：`guix-home-user` one-shot 重建链接；
- live reconfigure：`tools/reconfigure.sh` 在 system reconfigure 后
  显式 restart `guix-home-user` 并轮询验证链接指向 store（失败则
  gate 保持关闭）。stale pivot（`~/.guix-home.new`）由
  `tools/home-pivot.scm` 保守清理（只 unlink 指向 store home
  generation 的 symlink）。
