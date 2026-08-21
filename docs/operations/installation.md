# Installation

可直接照抄执行的安装 runbook。架构原理见
`architecture/{overview,storage,boot,persistence,accounts-sessions,home,secrets}.md`。

## 前置

- 仓库位于 LiveCD `/root/guix-configs`（VM 9p 共享或 clone）。
- LiveCD 根是内存盘；磁盘安装完成、目标挂到 `/mnt` 后、任何
  time-machine / `system init` 之前必须先 `herd start cow-store /mnt`
  （否则构建写满内存盘）。
- `@persist-var-guix` 在 init 期间刻意不挂载（`mount-at-install? #f`）
  ——init 会删除目标的 /var/guix 重新注册，挂载点删不掉（EBUSY）；
  commit-root 在快照前把内容收进子卷。

## 阶段 1：解锁 stable identity S

```bash
# master password 全程只输入一次（manifests/secrets.scm 提供 age/
# script/stty 工具链）
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secrets.scm -- \
  guile -L modules -s tools/secrets.scm unlock
```

得到 `/run/guixcfg-age/stable-identity`（0600，tmpfs）。所有 install
secret 解密复用它。

## 阶段 2：磁盘安装

```bash
# inspect / plan 只读；apply 破坏性，只对测试 VM 的 /dev/vda
guix shell -m manifests/installer.scm -- \
  guix repl tools/disk-install.scm -- inspect /dev/vda
guix shell -m manifests/installer.scm -- \
  guix repl tools/disk-install.scm -- plan vm /dev/vda

# apply：destructive 确认输入完整设备路径；LUKS passphrase 两种来源
#  交互：默认两次确认
#  --luks-secret：从 stable S 解密 secrets/install/luks-recovery.age
guix shell -m manifests/installer.scm -- \
  guix repl tools/disk-install.scm -- apply vm /dev/vda --luks-secret
```

成功标志：`Disk installation complete.`（GPT → ESP → LUKS2 → Btrfs
→ 持久子卷 → swapfile → @root-installing → /mnt 挂载 → facts 写入）。
LUKS UUID 记入 `/mnt/persist/system/facts/host.scm`。

## 阶段 3：cow-store

```bash
herd start cow-store /mnt
```

## 阶段 4：Secure Boot keygen（system init 前，让首次 UKI 已签名）

```bash
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secure-boot-keygen.scm -- \
  guix repl -L modules tools/secure-boot-keygen.scm /mnt/persist/system/keys/secure-boot
```
（`-L modules` 必需：工具自身不带 load path，缺了报
`no code for module (guixcfg storage model)`——2026-08 实测。）

## 阶段 4.5：Nonguix substitute bootstrap（首次 transition 必需）

本项目的 runtime kernel 是 Nonguix standard Linux
（docs/architecture/overview.md（Nonguix integration））。**当前
LiveCD/旧 daemon 只知道官方 Guix substitute**（bordeaux/ci）——
不 bootstrap 的话 `system init` 会在本地全量编译 kernel（数十分钟、
tmpfs 可能不够）。目标 installed 系统的 guix-daemon 配置（
`guix-service-type` 的 additive extension，
modules/guixcfg/system/substitutes.scm）**不会 retroactively 改变
当前已运行的 daemon**，因此首次 transition 必须显式 bootstrap：

```bash
# 1. 授权官方 Nonguix signing public key（当前 daemon 的 ACL；
#    key 是公开信任材料，canonical 副本在仓库：
#    modules/guixcfg/system/nonguix-key.pub）
guix archive --authorize < modules/guixcfg/system/nonguix-key.pub

# 2. system init 时显式提供 substitute URLs（pinned Nonguix README
#    的官方 bootstrap 方法；之后 installed daemon 已声明式配置，
#    不再需要）
GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm \
  guix time-machine -C channels.lock.scm -- system init \
  --substitute-urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://substitutes.nonguix.org' \
  -L modules modules/guixcfg/hosts/vm.scm /mnt
```

**昂贵构建预检**（development/testing.md）：`system init` 前先对
exact kernel 做 substitute-aware dry-run——kernel 必须显示为
download，而不是 will be built：

```bash
guix time-machine -C channels.lock.scm -- build --dry-run \
  -L modules -e '(@ (guixcfg system kernel-platform) %kernel)'
```

## 阶段 5：安装 stable S 到 persist

**必须先于 system init**：漏装/后装会导致首次启动的 secrets-deploy
无法解密（boot 后无 runtime identity，只用 installed identity），
interactive-secrets-ready 失败 → login barrier 卡死 → 无 login
prompt（已两次实测；secrets-deploy 与 commit-root 都会在缺失时
给出明确错误，但不要在第一次 boot 才暴露）。

```bash
install -d -m 700 /mnt/persist/system/keys/age
install -m 600 /run/guixcfg-age/stable-identity \
  /mnt/persist/system/keys/age/identity
```

验证：目录 0700、identity 0600、root。

## 阶段 6：system init

```bash
GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm \
  guix time-machine -C channels.lock.scm -- system init \
  --substitute-urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://substitutes.nonguix.org' \
  -L modules modules/guixcfg/hosts/vm.scm /mnt
```

成功标志：system-1-link、EFI/Guix/A/{CURRENT,RECOVERY}.EFI、
bootloader installed。有 db.key 则 UKI 已签名。

## 阶段 7：provision 用户密码 hash

```bash
GUIXCFG_ACCOUNTS_DIR=/mnt/persist/system/accounts \
  guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secrets.scm -- \
  guile -L modules -s tools/secrets.scm provision-password ordchaos \
  secrets/install/user-password.hash.age
```

验证：`/mnt/persist/system/accounts/ordchaos/password.hash`，root 0600。

## 阶段 8：commit-root

```bash
guix repl tools/disk-install.scm -- commit-root /mnt
```

兜底：若阶段 5 漏装 identity，commit-root 会从 /run 自动安装
（stage 5 fallback）；无 runtime identity（未 unlock）则明确报错，
提示先 secrets unlock。

成功标志：/var/guix adopted、@root-template 只读发布、@root-0
committed、state = `(boot-status . first-boot)`、UKI 部署 B committed。
重复执行是安全 no-op。

## 阶段 9：Secure Boot 固件注册（可选）

```bash
# keystore 构建
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secure-boot-enroll.scm -- \
  guix repl tools/secure-boot-enroll.scm /mnt/persist/system/keys/secure-boot

# 固件写入：db/KEK 先，PK 最后（写 PK 启用 Secure Boot）
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secure-boot-enroll.scm -- \
  sh -c 'sbkeysync --keystore /mnt/persist/system/keys/secure-boot/keystore --verbose &&
         sbkeysync --keystore /mnt/persist/system/keys/secure-boot/keystore --verbose --pk'
```

要求固件处于 Setup Mode（SecureBoot=0、SetupMode=1）。enrollment
失败不阻塞普通安装（可稍后在目标系统补做）。

## 阶段 10：仓库复制到 persistent user data

```bash
mkdir -p /mnt/persist/data-home/ordchaos/guix-configs
cd /root/guix-configs
tar cf - --exclude='./vms' --exclude='*.log' . | \
  tar xf - -C /mnt/persist/data-home/ordchaos/guix-configs
# uid/gid 字面量：1000 = %primary-user uid；998 = LiveCD users 组 gid
# （chown 在 LiveCD 上执行，目标账户还不存在，只能用数字——目标系统
# 的 users 组 GID 可能不同，但 boot 时 user-persistence activation
# 会按 passwd 重新 chown 顶层目录）。
chown -R 1000:998 /mnt/persist/data-home/ordchaos
```

验证 channels.lock.scm/modules/tools/docs/manifests 存在、无 vms 泄漏。

> 变体（无人值守安装/后续在已启动系统上以 root clone 或 pull）：同样
> 必须以 `chown -R <user>:users <backing>/guix-configs` 收尾。
> user-persistence activation 只 chown 顶层目录、不递归——root 克隆
> 的内容会一直 root:root，用户侧 `git pull` 报
> "cannot open '.git/FETCH_HEAD': Permission denied"（已实测一次）。

## 收尾（正常关机，不重启）

```bash
cd /root
herd stop cow-store
umount -R /mnt
sync
# 正常关机（安装完成绝不 reboot——2026-08 用户明确要求；
# LiveCD 无 poweroff 命令，用 shepherd 的关机动作）
herd power-off root
```

## TPM enrollment（Secure Boot 启用后，可选）

Secure Boot 已启用并完成一次带最终 NVRAM policy 的正常启动后：

```bash
guix shell tpm2-tools cryptsetup -- guix repl tools/tpm2-enroll.scm -- preflight
guix repl tools/tpm2-enroll.scm -- enroll      # 首次
guix repl tools/tpm2-enroll.scm -- status
guix repl tools/tpm2-enroll.scm -- replace     # Secure Boot policy 变化后
```

LUKS recovery passphrase 来源三选一（互斥；绝不静默回退）：

```bash
guix repl tools/tpm2-enroll.scm -- enroll                       # 交互读取
guix repl tools/tpm2-enroll.scm -- enroll --luks-secret         # age 解密
guix repl tools/tpm2-enroll.scm -- enroll --noninteractive      # stdin 直读
```

- `--luks-secret`：与 disk-install 的 apply 同一来源——stable S 解密
  `secrets/install/luks-recovery.age`（需先 `secrets unlock`；
  安装流程见 30.2.1）。runtime identity 缺失或解密失败立即中止，
  不会回退到交互输入；plaintext 不进 argv/env/log/store。
- `--noninteractive`：从 stdin 直读一行（脚本/自动化注入）。
- `status` / `preflight` 不接受任何 credential 来源 flag。
- 来源解析统一走 `(guixcfg security credential-source)`（与
  disk-install 共享同一 resolver；测试见 tests/test-credential-source.scm、
  tests/test-tpm2-enroll.scm 的 T7-T14）。
- **已装系统上 `--luks-secret` 不需要 unlock**：livecd 安装期用
  runtime identity（`/run/guixcfg-age/stable-identity`，需先
  `secrets unlock`）；已装系统自动改用 installed identity
  （`/persist/system/keys/age/identity`，日常可用）。两个 identity
  都缺失才中止（tests/test-credential-source.scm T1/T7）。

## 失败/重试边界

- 网络失败（channel fetch / substitute）：直接重跑该步。
- apply 在破坏磁盘后失败：按工具 fail/restart contract，测试 VM 可
  重建；绝不续跑中间态。
- commit-root 重复执行安全 no-op；sbkeysync 不重复写 PK。
