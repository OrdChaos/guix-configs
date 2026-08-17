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
| application data | `/persist/data-app` | 未实现（骨架） | — | yes | no |
| runtime secrets | `/run/guixcfg-secrets*` | consumers | projection exception | ephemeral | decrypt |
| Guix Home | `~/.guix-home` + dotfiles | — | symlink-manager | no | **yes** |

**Guix Home 是 derived state**：`~/.guix-home`、声明式 dotfiles 由
官方 guix-home-service-type activate 经 symlink-manager 恢复，不搬进
`/persist/data-home`。

未来 app persistence rule 必须指定：canonical backing、consumer
path、exposure、backup class、ownership、lifecycle。
