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
| user dirs | `/persist/data-home/user/<d>` | `/home/user/<d>` | directory bind | yes | no |
| guix-configs | `/persist/data-home/user/guix-configs` | `/home/user/guix-configs` | directory bind | yes | no |
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
owner        由 primary user / assembler 参数统一提供
```

**backup 是未来独立 concern**：contract 不要求 backup class；当前
不存在 backup subsystem，不制造 backup taxonomy。

机制（三路径安全，pinned Guix 行为审计）：

- bind mount 声明走 `file-systems`（`create-mount-point? #t`）——
  `/persist/data-app/<backing>` → `/home/<user>/<consumer>`；
- backing 目录与 consumer parent ownership 由系统 activation 创建
  （boot：activation 先于 shepherd file-systems 服务；system init /
  reconfigure 同样运行 activation）——`create-mount-point?` 以 root
  建挂载点，activation 恢复 intermediate parent 为用户所有，不留
  root-owned HOME hierarchy；
- 严格 validation：无 `..`、无绝对路径、非空、consumer 不得是
  `.config` / `.local` / `.local/share` / `.cache` 整体或前缀；
- 不产生 `/persist/data-nobackup` mapping；
- 不实现 copy/sync/boot-copy/seed-once/自动迁移。

当前没有真实 production application persistence rule（mechanism
ready, production rules pending explicit application adoption）。

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
