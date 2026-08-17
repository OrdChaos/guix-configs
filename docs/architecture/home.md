# Home Architecture

Guix Home 与用户数据边界。

## System / Home / Persistent data 三层边界

- **Guix System owns**：machine users/groups、`/etc/passwd` login
  shell、filesystem/mount topology、user persistence mappings、
  sshd/SSH policy/host keys、system services、boot/security。
- **Guix Home owns**：user packages、shell rc/config、aliases、
  environment、Git config、dotfiles、user services。
- **Persistent data layer owns**：user-created persistent data、SSH
  host private keys、later application state / private secrets。

Home 不挂载 /persist、不管理 sshd、不创建 private keys；System 不
重建用户数据。

## Ephemeral /home + bind-mounted 用户目录

`/home/user` 本身是 ephemeral（无状态 root）。初始持久目录由系统
从 `/persist/data-home/user/` bind mount：

```text
guix-configs / Projects / Documents / Downloads / Pictures
```

显式 ephemeral（本轮不持久化）：`~/.cache`、`~/.config`、
`~/.local`、`~/.mozilla`、`~/.steam`、整个 HOME。本轮不声称完整
用户状态持久化。

## Guix Home 是 derived state

`/home/user` 是 ephemeral；Guix Home 管理的一切都是 **derived
state**，由仓库 + 当前 system generation 重新生成——不持久化：

- `~/.guix-home` 与 dotfile symlinks 不属于 persistence inventory；
  每次 boot 由官方 `guix-home-service-type` 重新创建。

机制（官方 Guix 机制，无自定义重实现）：

- `home-environment`（`(guixcfg home user)` 的 `%guix-home`）经
  `(service guix-home-service-type ...)` 挂入 operating system，
  在 `guix system reconfigure` 时构建，成为 **system generation
  closure** 的一部分；
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
