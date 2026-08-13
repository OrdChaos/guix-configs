# 启动：Secure Boot、UKI 和 TPM


---

# 16. Secure Boot、UKI 和 TPM

## 16.1 Bootloader

不使用 GRUB。启动结构（已实现）：

```text
UEFI
  ↓
Limine（EFI/BOOT/BOOTX64.EFI fallback，无启动项也能进菜单）
  ↓
签名 UKI（ESP/EFI/Guix/{A,B}/*.EFI，efi_chainload）
  ↓
ephemeral-root-initrd
  ↓
LUKS2
  ↓
Btrfs root generation
```

菜单语义（docs/storage.md 第 17–18 章的两轴模型）：

```text
GNU Guix              当前系统 + 新建 fresh root（normal）
Previous boots        当前系统 + 历史 root（previous:K，折叠子菜单，
                      数量按部署时实际存在的 root 生成，最多 3 项）
GNU Guix (Recovery)   last-good Guix generation + last-good root
                      （两个轴各自最近确认值；无确认记录时不出现）
```

实现分层（GCD006 重写 Guix bootloader 框架时只需改适配层）：

```text
boot/uki-bootloader.scm   框架适配层（唯一依赖 <bootloader>/<menu-entry>）
boot/uki.scm              deploy-core：<boot-plan> + 部署脚本生成
boot/boot-state.scm       Boot State 注册表（Guix 轴的 last-good）
```

Recovery 的两个 last-good **有意不组成正常启动的稳定状态**：旧 root 只作为
数据丢失/误操作后的救援材料，只有 Recovery 可以把“旧 Guix generation”与
“旧 root”组合起来；Current/Previous boots 始终使用当前 Guix generation。
因此两个轴独立确认，不要求它们曾在同一次启动中配对验证。

部署使用 A/B 完整槽：`EFI/Guix/A/` 与 `EFI/Guix/B/`。每次只重建非活动槽，
所有 UKI 构建、签名和落盘完成后先原子更新 Limine fallback，最后以
`limine.conf` 的原子替换作为唯一 commit point。掉电最多留下一个未被菜单引用的
新槽，不会暴露半套 deployment。`.deployed` 只记录本项目拥有的路径；迁移旧
flat layout 时只对白名单中的旧 UKI 文件执行清理，不信任清单中的任意路径。

## 16.2 UKI

- 工具链：Rosenthal 频道的 `systemd-stub` + `ukify`（锁定在
  channels.lock.scm）。不依赖 systemd 作为 init/service manager。
- 组装在部署期进行（init/reconfigure）：部署脚本（Guix
  configuration-file 机制产出的 program-file）以 root 运行 ukify。
- 每个 A/B 槽内部的 UKI 命名固定（`CURRENT.EFI`、`PREV-K.EFI`、
  `RECOVERY.EFI`）；历史选择靠 initrd 的 `rootmode=previous:K` 相对选择器，
  菜单永不因 root 轮转而过期。
- Recovery UKI 的 Guix 轴数据源是 `/persist/system/boot-states.scm`；注册表同时
  保存该 generation 最后一次确认启动时的实际 kernel command line（剔除
  `rootmode=`），避免回到旧 Guix generation 时丢失 host 特有内核参数。
- **部署成功 ≠ 启动成功**：boot-state 与 root-state 都只由用户态确认服务更新。

## 16.3 Secure Boot

信任模型（实机策略）：自有 PK/KEK/db + 微软兼容证书 + 固件默认值。

```text
PK    只有我们自己的（平台所有权归本机）
KEK   我们的 KEK + Microsoft KEK CAs + 固件 KEKDefault
db    我们的 db + Microsoft db CAs（含 Option ROM UEFI CA 2023，
      显卡 OpROM 需要）+ 固件 dbDefault
```

- 密钥生成：`tools/secure-boot-keygen.scm`，通过
  `manifests/secure-boot-keygen.scm` 提供 `ukify`。
  只生成 PK/KEK/db 的 `*.key` + `*.crt` 到
  `/persist/system/keys/secure-boot/`（0700/0400，不进 Git、不进
  `/gnu/store`）；不承担任何固件 enrollment 工作，已存在任意密钥材料时拒绝覆盖。
- 微软证书：`(guixcfg security certificates)`，origin + 固定 sha256，
  经 store 取用；固件默认值经 `efi-readvar` 现读。
- 注册材料：`tools/secure-boot-enroll.scm` 通过
  `manifests/secure-boot-enroll.scm` 单独提供 enrollment 工具链，
  合并生成 sbkeysync keystore（`{PK,KEK,db}/*.auth`）。
  PK 最后写入。
- 签名在部署期：部署脚本探测到 `db.key`/`db.crt` 即让 `ukify`
  直接签 UKI，并用 `sbsign` 签 Limine；密钥不存在则全部不签（开发期）。
- keygen、UKI 部署、固件 enrollment 是三个独立阶段；
  enrollment 工具失败不得阻塞普通 Guix System 安装。
- 重装默认生成新的信任材料（删除旧密钥目录后重新 keygen）。

## 16.4 TPM2（PCR7-only，已实现）

> 状态：**PCR7-only 自动解锁已实现并通过单元测试与 T2 集成测试**。
> 实现分层：`tpm2-tools` 负责 PolicyPCR/seal/unseal（CLI 唯一出处
> 在 `(guixcfg security tpm2 tpm2-tools)`）；Scheme 只编排
> （enrollment `tools/tpm2-enroll.scm`、initrd 解锁
> `(guixcfg boot tpm-unlock)`）；**无** PCR11、无 PolicyAuthorize、
> 无 policy signing key、无 pending/active 授权状态。

### 兼容性与边界

Guix System 可以使用 TPM2，但项目不把它视为 Guix 原生的一等公民功能：
LUKS 仍由项目自定义 initrd 控制。TPM 自动解锁是 initrd 的一个受控解锁
路径，不要求 systemd 作为 PID 1。

行为（已实现）：

```text
正常启动
  Secure Boot policy 对应当前 PCR7 → TPM2 unseal 独立随机 LUKS
  credential → cryptsetup 自动解锁 → 进入系统
  ↓ 任何 TPM 错误 / PCR7 mismatch / TPM clear / artifact 错误
直接回退 cryptsetup 人工密码（永远不直接进 emergency shell）

Recovery（rootmode=recovery）
  不尝试 TPM → 始终人工密码
```

要求：TPM enrollment 在完整系统安装完成后、Secure Boot 已启用
（SecureBoot==1 且非 SetupMode）后执行；永远保留独立的密码 keyslot；
TPM 使用独立随机 LUKS credential/keyslot，不直接 seal 用户密码；
TPM 清空、主板更换、Secure Boot policy 改变后都可以用密码进入并
重新 enrollment（`replace` 子命令）。

### PCR policy（PCR7-only）

```text
PCR bank: SHA-256
PCR selection: 7（PolicyPCR）
sealed object policy: PolicyPCR(sha256:7) —— 绑定机器 Secure Boot
                      policy 状态，不绑定任何 UKI 内容
```

关键语义：

```text
PCR7 → 固件 Secure Boot policy 状态（SecureBoot 状态 + PK/KEK/db/dbx）
     → enrollment 时 seal 当前值
     → 不随 UKI/kernel/initrd/cmdline 更新变化（那些进 PCR4/11）
     → PK/KEK/db/firmware 变化导致 PCR7 变化 → unseal 失败 →
       密码回退 → 人工重新 enrollment（replace）
```

因此 **普通 UKI/kernel/initrd 更新无需重新 enrollment**——TPM 材料是
机器级状态，不是 UKI slot 级状态（这正是相对旧 PCR11 设计的架构收益）。

安全边界（如实说明）：PCR7-only 不绑定"必须是我们的 UKI"——任何在
该机器 Secure Boot policy 下可启动的代码（含微软签名 shim/GRUB 链）
都能触发 unseal。它防的是磁盘被拆走单独解密、policy 被篡改、TPM
被清空；不防"攻击者在这台机器上启动任意签名系统"。对个人笔记本的
威胁模型（失窃/磁盘拆卸）足够；密码 keyslot 永远是最终兜底。

### 组件与 artifact 布局

```text
/persist/system/tpm2/state.scm      enrollment 元数据（原子写 + .prev）
/persist/system/tpm2/objects/       sealed blobs 管理副本（seal.pub/priv）
ESP /EFI/Guix/tpm2/                 【解锁前读取】seal.pub / seal.priv /
                                    metadata.scm（enrollment 工具发布；
                                    不随 UKI slot 变化，initrd 固定路径）
```

解锁 LUKS **之前**必须读取的数据不能只放在 `/persist/system`（访问它
要先解锁 LUKS，循环依赖）；sealed blob 非秘密（TPM 密封对象不含明文），
放 ESP 即可，篡改只造成 DoS → 密码回退。

### enrollment（tools/tpm2-enroll.scm）

```text
preflight  检查 TPM 可用 / 非 Recovery / LUKS2 / SecureBoot==1 且
           SetupMode==0 / ESP 挂载 / persist 可写
enroll     验证 recovery 密码（--test-passphrase）
           → 生成 32 字节随机 credential（hex，仅内存）
           → 读当前 PCR7 → trial PolicyPCR(sha256:7) → create sealed
           → unseal 自验证 → luksAddKey 独立 keyslot（credential 经
             stdin；recovery 密码经 0600 临时文件——cryptsetup
             --key-file=- 是读到 EOF 语义，无法与 --new-keyfile=-
             共享 stdin，实测）
           → 新 keyslot 验证 → 发布 ESP artifact（失败回滚
             luksKillSlot）→ /persist 副本 + 原子写 state
replace    先加新 keyslot 再发布，旧 TPM keyslot 保留为历史材料
           （绝不先删旧）；recovery keyslot 永不触碰
status     显示 enrollment 与两侧 artifact 完整性
```

时点要求：必须在 Secure Boot 已真正启用并完成一次带最终 NVRAM policy
的正常启动之后执行（安装 ISO 阶段不 seal）。完整流程：

```text
install → Secure Boot enroll（sbkeysync，PK 最后写）→ reboot
→ 确认 SecureBoot=1 / SetupMode=0 → tpm2-enroll preflight/enroll
→ reboot → 验证自动解锁
```

### initrd 解锁流程（已实现）

```text
mapped-device open（luks-tpm2-device-mapping，config 侧定义）
  ↓
tpm-unlock-in-initrd：
  cmdline 门控（rootmode=recovery / guixcfg.tpm-unlock=0 → 跳过）
  → /dev/tpmrm0 存在？
  → /sys/block PARTNAME 发现 system/esp 分区（initrd 无 udev）
  → 挂 ESP → 读 EFI/Guix/tpm2/{seal.pub,seal.priv}
  → createprimary（确定性 SRK，无持久句柄）→ load sealed
  → policy session（实际 PCR7）→ unseal stdout
  → 管道直连 cryptsetup open --key-file=-（明文不落盘/不进 argv/env）
  → 成功 → #t；任意失败 → 打印一行原因 → #f
  ↓
#f → 与 luks-device-mapping 相同的分区发现（find-partition-by-luks-uuid
     10 秒重试）+ cryptsetup 交互密码
```

### 实测知识（tpm2-tools 5.7 / swtpm，本项目验证）

```text
- tcti-swtpm 无 resource manager：ContextLoad 每次占新 transient
  slot，不 flush 会 0x902；测试环境每命令后 tpm2_flushcontext -t
  （只 flush transient，不碰 sessions——AUTOFLUSH=yes 会杀 session，
  0x70018）；生产 /dev/tpmrm0 由内核 RM 回收，禁止全局 flush；
- tpm2_policypcr 指定期望值用 -f <pcrread 原始输出> + -l bank:index；
  -l "bank:index=值" 前向封印在 swtpm TCTI 下 0x1C4；
- tpm2_create -L <文件> 在 swtpm 下 0x902，-L hex 正常；
- cryptsetup --key-file=- 是"读到 EOF"语义（无换行剥离）：
  安装/解锁的 passphrase 字节必须精确一致；luksAddKey 无法双 stdin；
- swtpm 测试必须用宿主 tpm2-tools（store 包不带 tcti-swtpm 插件）；
- initrd 模块闭包不能引入 (guix gexp)/(guix utils)（version-compare
  dlsym strverscmp，guile-static-initrd 静态链接无法解析）——kind
  定义在 config 侧，initrd 只带运行时模块。
```

### 测试

```text
单元：tests/test-tpm2-state.scm（enrollment 状态）、
      tests/test-tpm-unlock.scm（门控/决策）
T2：  tools/test-tpm2-poc.sh（swtpm PolicyPCR 机制：seal/unseal、
      extend 后失败）
      tools/test-tpm2-luks.sh（真实 cryptsetup：T2-1 自动解锁 /
      T2-2 PCR 变化回退 / T2-3 blob 损坏回退 / T2-4 TPM clear 回退 /
      T2-5 Recovery 门控）
T3：  tools/t7-e2e.sh + tools/t7-scenario.sh（OVMF Secure Boot +
      swtpm + 签名 UKI 场景：auto-unlock / secboot-off / tpm-clear /
      corrupt / recovery）
```

## 16.5 内核模块签名

Secure Boot 开启后内核进入 lockdown，未签名的外部内核模块（如 NVIDIA 专有模块）会被拒绝加载。因此：

目标规则：

- 外部内核模块在安装时和每次变更后均使用本项目 Secure Boot 密钥自签名；
- 签名必须成为 system generation 构建/部署的一部分，与内核版本绑定；
- 使用内核提供的 `scripts/sign-file`/等价打包阶段，而不是对运行中的
  `/gnu/store` 内容事后原地补签；
- 签名后的模块随 system generation 一起部署和回滚。

**当前尚未实现该步骤。** Laptop host 目前也尚未组装最终 NVIDIA configuration，
所以这不是 VM Secure Boot 的 blocker，但在 Laptop 实机启用 Secure Boot +
NVIDIA 专有模块之前必须实现并验证。文档不再把它描述成已经存在的部署能力。
