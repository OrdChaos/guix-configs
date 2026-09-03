# Installation

安装生命周期（Blue 主路径）：

```text
LiveCD / installer environment
  ↓
blue -n install HOST DEVICE     # 只读 preflight + 完整安装计划（零 mutation）
blue install HOST DEVICE        # 破坏性确认后一次性完成可启动安装
  ↓
reboot（绝不自动 reboot）
  ↓
installed system（首次正常启动）
  ↓
blue -n firstboot HOST          # 只读：reconfigure 推导 plan + enrollment 计划
blue firstboot HOST             # 首次启动收敛：reconfigure（system + Home）
                                #   → enroll（TPM / Secure Boot 固件注册）
  ↓
normal operation
```

- `blue install HOST DEVICE` = 从空白/可复用磁盘到「可启动、完整配置、
  已验证」的目标系统（含仓库 checkout 复制到
  `/persist/data-home/<user>/guix-configs`）；**不包含** TPM final
  enrollment 与固件 PK enrollment（归 `blue enroll`）。
- `blue firstboot HOST` = 首次正常启动后的一键收敛：先
  `reconfigure`（把 system + Home 收敛到本 checkout），再 `enroll`
  （把实际机器绑定到系统）。任一相位失败即整体失败（该相位退出码）。
- `blue enroll HOST` = 单独重跑机器绑定（Secure Boot 固件注册 → TPM
  enrollment → post-enrollment 验证）——Secure Boot policy 变化后的
  `replace`、TPM 重建等场景；`blue firstboot` 的 enroll 相位与它
  完全同机制。
- HOST 与 DEVICE 均显式：无 fallback、无 hostname/machine-id 自动检测。
- dry-run（`blue -n`）零 mutation、不 sudo、不要求确认。
- 退出码：`0` 成功/已合规；`1` 前置失败（未 mutation）；`2` 部分
  mutation 无法安全自动继续；`3` 用户显式中止。
- resume：已完成的阶段按可观察事实检测并跳过；ambiguous /
  incompatible 部分状态 fail closed（绝不自动重新格式化）。

本文档主体是 Blue 主路径；下方「手动 runbook」是同一流程的底层阶段
细节（专家 / 恢复参考，`blue install` 按此顺序编排），出问题时的手工
入口见 `recovery.md` 与各 tools（disk-install / secrets /
secure-boot-keygen / secure-boot-enroll / tpm2-enroll）。

## 前置

- 仓库位于 installer 环境可读位置（如 LiveCD 的 `/root/guix-configs`，
  VM 9p 共享或 clone）。Blue 经 development manifest 提供：
  `guix time-machine -C channels.lock.scm -- shell -m manifests/development.scm -- blue …`。
- 阶段 5（安装 stable identity 到 persist）必须先于 system init（
  `blue install` 的 secrets 阶段自动保证此顺序；AGENT.md §5）。
- `@persist-var-guix` 在 init 期间刻意不挂载（`mount-at-install? #f`）
  ——init 会删除目标的 /var/guix 重新注册，挂载点删不掉（EBUSY）；
  commit-root 在快照前把内容收进子卷。
- LiveCD 根是内存盘：`blue install` 的 system-init 阶段会自动检测
  `/gnu/store` 在 tmpfs 并先 `herd start cow-store /mnt`（herd 缺失
  即 fail closed）。

## Blue 主路径

```bash
# installer 环境（LiveCD）
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- \
  blue -n install laptop /dev/nvme0n1

guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- \
  blue install laptop /dev/nvme0n1

# 关机重启进入已安装系统（安装完成绝不自动 reboot）

blue -n firstboot laptop
blue firstboot laptop          # = reconfigure + enroll（见「首次启动」一节）

# 单独重跑机器绑定（policy 变化后的 replace / TPM 重建等）：
blue -n enroll laptop
blue enroll laptop
```

`blue install` 的真实阶段（`blue -n install` 打印同一计划；已完成的
阶段自动 skip）：

```text
  preflight        installer 环境检查（root/工具/设备/host policy/UEFI）
  disk             GPT + LUKS2 + Btrfs 布局（fresh 才执行；
                   破坏性确认 = 逐字输入完整 DEVICE）
  mounts           resume：打开 LUKS + 重放 mount 步骤
  facts            /mnt/persist/system/facts/host.scm（幂等重写）
  sb-keys          Secure Boot keygen（db.key/db.crt 供 init 期 UKI 签名）
  secrets          stable identity + 用户密码 hash 安装到 /mnt/persist
  sb-keystore      sbkeysync keystore 构建（不写固件）
  system-init      GUIX_CONFIG_FACTS + guix system init → /mnt
  commit-root      @root-template 只读发布 + @root-0（幂等 + 中断恢复）
  repo             仓库 checkout 复制到 /mnt/persist/data-home/<user>/
                   guix-configs（runbook 阶段 10 机制化；tar 排除
                   vms/*.log + chown -R 归还 USER ownership）
  validate         /mnt 布局 / facts / system generation / ESP artifacts /
                   secrets / commit state / SB key material / repo copy
                   逐项复核
```

repo 阶段语义：检测 = `channels.lock.scm`/`modules`/`tools`/`docs`/
`manifests`/`.git` 全部在位 → complete（skip）；缺失/部分 → 幂等重放
tar 复制（resume 安全）。`.git` 刻意保留——已装系统上用户
`git pull` 更新仓库的入口；install 的 repo 复制只做 bootstrap，后续
更新走正常 git 流程（AGENT.md §5 的 ownership 收尾语义在复制时一次
性完成，boot 期 user-persistence activation 只 chown 顶层目录）。

identity unlock（runbook 阶段 1 的语义已并入 `blue install`）：runtime
与 installed identity 都缺失时，事务前置会交互提示 master password
解锁 stable S（失败 exit 1、未 mutation）。LUKS passphrase 来源：
identity 已就位时走 `luks-recovery.age`（age 解密，不提示密码）；
否则交互两次确认（credential-source 的同一 resolver，绝不静默回退）。

`blue enroll` 的真实阶段（`blue -n enroll` 打印同一计划）：

```text
  preflight        目标系统环境（/run/current-system、/persist、ESP、
                   TPM 设备、SB keys/keystore、sbkeysync、facts）
  firmware         Setup Mode 时：显式确认 → sbkeysync db/KEK →
                   sbkeysync --pk（写 PK 退出 Setup Mode）
                   （SecureBoot=1 && SetupMode=0 时 skip）
  tpm              absent → tpm2-enroll enroll --luks-secret（幂等自动）；
                   compatible → skip；incomplete → fail closed（不自动 replace）
  validate         TPM compatible + firmware 状态 + artifacts 复核
```

固件写入确认：打印当前固件状态、计划操作与回滚/恢复影响，逐字输入
`ENROLL-FIRMWARE` 才继续（其他输入/EOF 一律中止）。TPM enrollment
是幂等的，自动执行，不额外确认。

## 首次启动（blue firstboot）

第一次正常启动时**自动**发生的事情（无需手动步骤）：

- boot readiness 链（persistent-state-ready → account-state-ready →
  interactive-secrets-ready → home-ready → session-infra-ready）完成
  后 login gate 打开——首次 boot 即完整系统；
- **Guix Home 首次投影由官方 `guix-home-service-type` 在 boot 时
  自动激活**（pinned Guix gnu/services/guix.scm：shepherd 以 USER
  身份运行 Home generation 的 `/activate`，provision
  `guix-home-<user>`）。因此仓库派生的用户资源（assets/ 的
  avatar/wallpaper → `~/.local/share/avatars|backgrounds/`）在首次
  boot 就位——**既不在 `blue install` 里复制，也不需要手动
  reconfigure**；install 期它们被编入 system generation closure，
  boot 期投影到 $HOME（`(guixcfg home assets)` 的
  home-files-service-type 链接）。仓库内 assets 更新后走
  `blue firstboot` / `blue reconfigure`（Home 热激活）生效。

之后的一键收敛：

```bash
blue -n firstboot laptop   # 只读：reconfigure 推导 plan + enrollment 计划
blue firstboot laptop
```

两个相位顺序固定：

1. **reconfigure 相位** = `blue reconfigure HOST` 的完整机制（doctor
   含 git clean gate → gate transaction：system reconfigure → Home
   热激活 → readiness 复查 → gate 重开）。作用：把系统收敛到当前
   checkout（安装后仓库如有新提交——如 `git pull` 之后——在这一步
   部署）。失败（exit 1/2）即整体失败，enroll 不执行。
2. **enroll 相位** = `blue enroll HOST` 的完整机制（固件状态
   preflight → Setup Mode 时显式确认写 db/KEK/PK → TPM enrollment
   → validate）。失败（exit 1/2/3）整体失败。

之后日常更新只用 `blue reconfigure HOST`；机器绑定重做只用
`blue enroll HOST`。

---

# 手动 runbook（专家 / 恢复参考）

以下阶段是 `blue install` 编排的底层细节（机制 authority 不变）；
主路径用户不需要手工执行，恢复/诊断时按需使用。

## 阶段 1：解锁 stable identity S

```bash
# master password 全程只输入一次（manifests/secrets.scm 提供 age/
# script/stty 工具链）
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secrets.scm -- \
  guile -L "$PWD/modules" -s tools/secrets.scm unlock
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
#  --luks-secret：从 stable S 解密 modules/guixcfg/security/secrets/luks-recovery.age
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
  guix repl -L "$PWD/modules" tools/secure-boot-keygen.scm /mnt/persist/system/keys/secure-boot
```
（`-L "$PWD/modules"` 必需：工具自身不带 load path，缺了报
`no code for module (guixcfg storage model)`——2026-08 实测。）

## 阶段 4.5：Nonguix 包本地构建预检（首次 transition 必需）

本项目的 runtime kernel 是 Nonguix standard Linux 7.2
（docs/architecture/overview.md（Nonguix integration））。**第三方
substitute（substitutes.nonguix.org）已移除（2026-08-25 决策）**——
nonguix 包（kernel/firmware/microcode）一律本地编译：`system init`
会本地全量编译 kernel（数十分钟；编译产物进 store，之后复用）。

**构建临时目录**：仓库系统的 guix-daemon 已显式声明
`TMPDIR=/var/tmp`（%common-services 的 guix-configuration tmpdir
字段；默认 /tmp 是 7.7GB tmpfs，装不下内核编译 ~11GB 中间产物——
2026-08-25 实测）。**主机**（Arch systemd daemon）需单独配置：
`/etc/systemd/system/guix-daemon.service` 的 Environment 行加
`TMPDIR=/var/tmp` 后 `systemctl daemon-reload && systemctl
restart guix-daemon`。

**昂贵构建预检**（development/testing.md）：`system init` 前先对
exact kernel 做 dry-run，确认产物已在 store（或接受本地编译时长）：

```bash
guix time-machine -C channels.lock.scm -- build --dry-run \
  -L "$PWD/modules" -e '(@ (guixcfg system kernel-platform) %kernel)'
```

输出为 store 路径 = 已缓存；输出 `would be built` = 需要本地编译。

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
  -L "$PWD/modules" modules/guixcfg/hosts/vm.scm /mnt
```

成功标志：system-1-link、EFI/Guix/A/{CURRENT,RECOVERY}.EFI、
bootloader installed。有 db.key 则 UKI 已签名。

## 阶段 7：provision 用户密码 hash

```bash
GUIXCFG_ACCOUNTS_DIR=/mnt/persist/system/accounts \
  guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secrets.scm -- \
  guile -L "$PWD/modules" -s tools/secrets.scm provision-password ordchaos \
  modules/guixcfg/users/secrets/user-password.hash.age
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

> `blue install` 的 repo 阶段已把本段自动化（检测/复制/chown/验证，
> 见 Blue 主路径）；以下为机制细节与恢复/专家参考。

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
  `modules/guixcfg/security/secrets/luks-recovery.age`（需先 `secrets unlock`；
  安装流程见阶段 1）。runtime identity 缺失或解密失败立即中止，
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
