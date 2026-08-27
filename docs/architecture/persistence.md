# Persistence Architecture

核心不变量：**Persistent mutable state has ONE canonical backing
object。**

每一份 mutable persistent data 只在持久层存在一个 canonical backing。
应用路径通过 bind mount / symlink / direct reference 访问同一
backing；禁止 boot copy → ephemeral、shutdown copy → persistent 的
双副本同步模型。

## Exposure primitives

| primitive | 用途 |
|---|---|
| bind mount | 目录型 mutable data（用户目录、standalone file 容器）；对应用透明 |
| symlink | 单文件引用（consumer 接受 symlink、不原子替换目标时） |
| direct reference | consumer 配置直接指向 canonical path（如 sshd HostKey） |
| hard link | 不作为 persistence deployment mechanism |

**Hard link 排除理由**：persistence 与 ephemeral root 在不同 Btrfs
subvolume；hardlink 不适合跨 subvolume deployment contract；应用常见
atomic replace（write temp → rename）产生新 inode，破坏 hardlink；
难以从 pathname 审计 canonical ownership。

## Projection exceptions

以下允许 runtime materialization，不违反 single-backing：

1. `/etc/{passwd,group,shadow}` — composite account database，由
   generation topology + persistent credential 合成；唯一 writer 是
   account databases projection；
2. `/run/guixcfg-secrets*` — plaintext runtime secret 本身不
   persistent；source 是 ciphertext + identity，运行时解密；
3. Guix/UKI/build artifacts — generated/immutable deployment
   artifacts；
4. 必须生成的 cache/index — 可重建且 ephemeral。

## Persistence inventory

| logical state | canonical backing | consumer | exposure | mutable | derived |
|---|---|---|---|---|---|
| `/gnu/store` | `@persist-gnu-store` | `/gnu/store` | direct（subvol mount） | no | no |
| `/var/guix` | `@persist-var-guix` | `/var/guix` | direct（安装期不挂） | yes | no |
| user dirs | `/persist/data-home/<user>/<d>` | `/home/<user>/<d>` | directory bind | yes | no |
| guix-configs | `/persist/data-home/<user>/guix-configs` | `/home/<user>/guix-configs` | directory bind | yes | no |
| SSH host keys | `/persist/system/ssh/ssh_host_ed25519_key` | sshd HostKey | direct reference | yes | no |
| age identity | `/persist/system/keys/age/identity` | secrets 解密 | direct reference | yes | no |
| Secure Boot keys | `/persist/system/keys/secure-boot/*` | UKI 签名/enrollment | direct reference | yes | no |
| TPM state | `/persist/system/tpm2` | tpm2-enroll | direct | yes | no |
| password.hash | `/persist/system/accounts/<user>/password.hash` | account projection | direct reference | yes | no |
| root-generation state | `/persist/system/root-generations/state.scm` | initrd + confirm/cleanup | direct reference | yes | no |
| application data | `/persist/data-app/<backing>` | `/home/<user>/<consumer>` | directory bind（generic engine） | yes | no |
| runtime secrets | `/run/guixcfg-secrets*` | consumers | projection exception | ephemeral | decrypt |
| Guix Home | `~/.guix-home` + dotfiles | — | symlink-manager | no | **yes** |

**Guix Home 是 derived state**：`~/.guix-home`、声明式 dotfiles 由
官方 guix-home-service-type activate 经 symlink-manager 恢复，不搬进
`/persist/data-home`。

## Application persistence（/persist/data-app）

generic engine：`modules/guixcfg/system/application-persistence.scm`
（不知道具体应用名；rule 由 application definition 提供，host 经
registry 聚合）。

每个 rule 必须指定（persistence contract）：

```text
logical name
backing      /persist/data-app 下相对路径（唯一 canonical backing）
consumer     HOME 相对路径（bind projection）
exposure     仅 bind-directory（第一版）
lifecycle    仅 application-owned
seeds        可选：首次初始状态（(target source) 列表，seed-once）
owner        由 primary user / assembler 参数统一提供
```

**backup 是未来独立 concern**：contract 不要求 backup class；当前
不存在 backup subsystem，不制造 backup taxonomy。

机制（三路径安全，pinned Guix 行为审计）：

- bind mount 声明走 `file-systems`（`create-mount-point? #t`）——
  `/persist/data-app/<backing>` → `/home/<user>/<consumer>`；
- backing 目录与 consumer parent 层级 ownership 由系统 activation 创建
  （boot：activation 先于 shepherd file-systems 服务；system init /
  reconfigure 同样运行 activation）——`create-mount-point?` 与 activation
  的 `mkdir-p` 都以 root 建路径，activation 必须把【每一层】intermediate
  parent 都 chown 回用户所有（只 chown 直接 parent 会留下 root-owned
  `~/.local`：Guix Home activation 以用户身份 `mkdir ~/.local/share`
  时 EACCES，Home 整体失败——boot 实测 2026-08-19，回归测试
  `test-runtime-exec.scm` AP1）；
- 严格 validation：无 `..`、无绝对路径、非空、consumer 不得是
  `.config` / `.local` / `.local/share` / `.cache` 整体或前缀；
- 不产生 `/persist/data-nobackup` mapping；
- 不实现 copy/sync/boot-copy/自动迁移。

**seed-once（首次初始状态）**：rule 可声明 `seeds`（`(target
source)` 两元素列表；source 为 file-like），语义是"只负责创建一
个从未存在过的用户状态，创建成功后永久放弃 ownership"：

- 每次系统 activation 检查 **canonical backing 侧**的
  `<backing>/<target>.seed-provided` marker（空文件，presence =
  状态）与目标文件：
  - marker 存在 → 已提供过，永不重复（即使目标被 app/用户删除；
    删除 marker + 目标 = 显式重新 seed 的维护操作）；
  - marker 缺失、目标存在 → 完全保留（备份恢复/崩溃窗口），补写
    marker 固化决策，**绝不比较/merge/patch/覆盖**；
  - 均缺失 → 原子写入（`.new` → fsync → rename → fsync 父目录，
    `(guixcfg utils atomic-file)`），再写 marker——中途崩溃不会留
    下可被误判为已初始化的半成品；
- **seed-once != declarative management**：seed 之后 repository 对
  该文件零写入，后续 reconfigure/seed 更新都不影响已初始化目标；
- 实现：`(guixcfg utils seed-once)`（状态机）+ application
  persistence activation 接线；生产 consumer：noctalia-git
  （`.local/state/noctalia/settings.toml` 初始配置）。

production consumers：
- mpv（`.local/state/mpv` → `/persist/data-app/mpv/state`，
  watch-later resume；`apps/mpv/definition.scm`）；
- gnome-keyring（`.local/share/keyrings` →
  `/persist/data-app/gnome-keyring/keyrings`，login keyring vault——
  sensitive mutable state；`apps/gnome-keyring/definition.scm`，
  迁移说明见 `desktop-authentication.md` §5）；
- google-chrome-stable（`.config/google-chrome` →
  `/persist/data-app/google-chrome-stable/user-data`，Chromium 官方
  User Data Directory 整体——不做 profile 内部细分；`~/.cache/
  google-chrome` 保持 ephemeral；`apps/google-chrome-stable/
  definition.scm`）；
- fcitx5（`.local/share/fcitx5/rime/rime_ice.userdb` →
  `/persist/data-app/fcitx5/rime_ice.userdb`，Rime 用户学习词库——
  雾凇主翻译器唯一可写 leveldb；`*.custom.yaml` 为 declarative
  repo-owned，`build/`/`user.yaml`/`installation.yaml` 保持
  ephemeral；`apps/fcitx5/definition.scm`）。

后续应用按同一契约显式 adopt。

## data-nobackup storage class

`/persist/data-nobackup`（@persist-data-nobackup 子卷）是固定挂载点
上的 **persistent bulk/reacquirable storage**：Steam game libraries、
downloadable models、VM images 等大体积且原则上可重新取得的数据。

使用方式：application explicitly configured to
`/persist/data-nobackup/<something>`（direct access）——不是
`/persist/data-nobackup/... → bind → HOME/FHS`。

因此：不加入 application persistence registry；不为每项数据建立
bind mount；System 只负责整个子卷固定挂载；application 主动知道
路径；`nobackup` 名称只表示 storage intent——当前无 backup
subsystem。

## Machine-owned mutable system state（/persist/system/state）

第四种 persistence ownership（详细见 `docs/architecture/machine-state.md`）：

```text
/persist/data-home       user-owned data
/persist/data-app        application-owned mutable user state → HOME bind
/persist/data-nobackup   bulk/reacquirable direct-access data
/persist/system          machine-owned identity/state
                            ├── identity/keys
                            ├── provisioning state
                            └── mutable daemon/system state
                                （/persist/system/state → /etc、/var/lib 等
                                  absolute system consumer 的 bind projection）
```

generic mechanism：`modules/guixcfg/system/machine-state-persistence.scm`
（`<machine-state-persistence-rule>`：name/backing/consumer/exposure/
lifecycle；root = `persist-mount-point "@persist-system"` + `/state`；
bind-directory only；machine-owned only；root ownership）。

与 application persistence 的区别：后者是 `/persist/data-app` →
HOME-relative consumer；machine state 是 `/persist/system/state` →
**absolute system consumer**。与 declarative secret 的区别：
`<模块>/secrets/*.age`（与引用者同置）是 repository authority
（declarative ciphertext）；`/persist/system/state` 是 machine
authority（本机产生的 mutable state，独立于 repository）。

当前无真实 production rule（NetworkManager 只作 canonical example，
未启用——见 machine-state.md）。

## Mixed-authority state container（Phase A，2026-08）

> **Directory membership does not imply common authority.** authority
> 按可独立管理的 path/node 判断，不是按目录整体。

决策优先级（docs/development/applications.md 有完整决策树）：

1. **Preferred 1 — separate state directory**：app 已有独立
   XDG/data/state namespace（`.config/foo` repo + `.local/state/foo`
   app）→ 只持久化后者；
2. **Preferred 2 — mutable subdirectory**：`.config/foo/state/` →
   `/persist/data-app/foo/state` → bind；
3. **Fallback — mixed persistent container**：declarative + app-written
   文件不可避免同处一个 app-private 目录时：

   ```text
   /persist/data-app/fish/config
           ↓ bind
   ~/.config/fish
           ├── config.fish      → /gnu/store  repo authority
           └── fish_variables                app authority
   ```

物理 backing 属于 persistence substrate；逻辑 authority 仍 per-path。

硬约束：

- mixed container 只允许 app-private namespace（`.config/<app>`、
  `.local/share/<app>`）；公共 XDG root（`.config`、`.local`、
  `.local/share`、`.cache`、`~`）禁止整体交给 persistence rule；
- **single-file bind 不是标准机制**（第一版仍 directory bind only）：
  应用普遍用 write-temp→fsync→rename 原子替换，单文件 mountpoint/
  symlink target 会破坏 rename、被应用替换 symlink、触发 EXDEV/
  EBUSY、破坏应用自身 crash-safety；
- **dual authority 是错误**：repo/Home 管理 config.toml 同时应用也
  改写它 = 非法；必须选择 repo-owned（应用禁用 auto-write）或
  app-owned（Home 停止声明），**不做自动 merge / conflict
  resolution**；
- generation 语义：declarative occupants 随 System/Home generation
  （rollback 也跟随）；mutable occupants 随 machine runtime
  history（**不随 generation rollback**）——预期行为；
- stale declarative occupants：pinned Guix Home symlink-manager 在
  generation 切换时清理旧代声明的 store symlinks（仅删 store
  symlink；非 store symlink 跳过；非空/挂载目录跳过）——**无需
  custom occupant inventory**（pinned 行为实测，tests/
  test-mixed-authority.scm）。
