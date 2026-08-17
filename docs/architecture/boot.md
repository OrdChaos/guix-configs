# Boot Architecture

固件、Secure Boot、Limine、UKI、initrd、root generation 选择、TPM。
安装期命令在 `operations/installation.md`；测试层级见
`development/testing.md`。

## Boot chain

```text
UEFI
  ↓
Limine（EFI/BOOT/BOOTX64.EFI fallback，无启动项也能进菜单）
  ↓
签名 UKI（ESP/EFI/Guix/{A,B}/*.EFI，efi_chainload）
  ↓
ephemeral-root-initrd
  ↓
LUKS2（TPM PCR7 自动解锁或人工密码）
  ↓
Btrfs root generation
```

## 菜单语义（两轴模型）

```text
GNU Guix              当前系统 + 新建 fresh root（normal）
Previous boots        当前系统 + 历史 root（previous:K，最多 3 项）
GNU Guix (Recovery)   last-good Guix generation + last-good root
```

两轴（root 轴 = Btrfs generation，Guix 轴 = system generation）
**正交独立确认**。Recovery 有意组合"旧 Guix generation + 旧 root"，
但不把这对组合提升为正常启动的稳定状态；Current/Previous 始终用
当前 Guix generation。**部署成功 ≠ 启动成功**：boot-state 与
root-state 都只由用户态确认服务更新。

## UKI

- 工具链：Rosenthal 频道的 `systemd-stub` + `ukify`（锁定
  channels.lock.scm），不依赖 systemd 作为 init。
- 组装在部署期（init/reconfigure）以 root 运行 ukify。
- A/B 完整槽：`EFI/Guix/{A,B}/`。每次只重建非活动槽；所有构建、
  签名、落盘完成后先原子更新 Limine fallback，最后以 `limine.conf`
  原子替换为唯一 commit point。掉电最多留下未被菜单引用的新槽。
- 槽内命名固定（`CURRENT.EFI`、`PREV-K.EFI`、`RECOVERY.EFI`）；
  历史选择靠 initrd 的 `rootmode=previous:K` 相对选择器，菜单永不
  因 root 轮转过期。
- Recovery UKI 的 Guix 轴数据源：`/persist/system/boot-states.scm`
  （保存 last-good generation 及实际 kernel command line，剔除
  `rootmode=`）。

## Secure Boot

信任模型：自有 PK/KEK/db + 微软兼容证书 + 固件默认值。

```text
PK    只有我们自己的（平台所有权归本机）
KEK   我们的 KEK + Microsoft KEK CAs + 固件 KEKDefault
db    我们的 db + Microsoft db CAs（含 Option ROM UEFI CA 2023）+ 固件 dbDefault
```

- 密钥生成：`tools/secure-boot-keygen.scm`（manifests 提供 ukify），
  只生成 PK/KEK/db 的 key+crt 到 `/persist/system/keys/secure-boot/`
  （0700/0400，不进 Git/store）；已存在材料时拒绝覆盖。
- 微软证书：`(guixcfg security certificates)`（origin + 固定 sha256）；
  固件默认值经 `efi-readvar` 现读。
- 注册材料：`tools/secure-boot-enroll.scm` 合并生成 sbkeysync
  keystore（`{PK,KEK,db}/*.auth`）；PK 最后写入。
- 签名在部署期：探测到 `db.key`/`db.crt` 即让 ukify 签 UKI、
  sbsign 签 Limine；密钥不存在则全部不签（开发期）。
- keygen / UKI 部署 / 固件 enrollment 是三个独立阶段；enrollment
  失败不得阻塞普通安装。

## TPM2（PCR7-only）

LUKS 由项目自定义 initrd 控制；TPM 自动解锁是 initrd 的一个受控
解锁路径，不要求 systemd 作 PID 1。

```text
正常启动
  Secure Boot policy 对应当前 PCR7 → unseal 独立随机 LUKS credential
  → 自动解锁 → 进入系统
  ↓ 任何 TPM 错误 / PCR7 mismatch / TPM clear / artifact 错误
直接回退人工密码（永不直接进 emergency shell）

Recovery（rootmode=recovery）：不尝试 TPM → 始终人工密码
```

PCR policy：SHA-256，只选 PCR7（PolicyPCR）。sealed object policy =
PolicyPCR(sha256:7)，绑定机器 Secure Boot policy 状态，不绑定 UKI
内容。因此普通 UKI/kernel/initrd 更新无需重新 enrollment；PK/KEK/db
变化导致 PCR7 变化 → unseal 失败 → 密码回退 → `replace` 重新
enrollment。

安全边界：PCR7-only 不绑定"必须是我们的 UKI"——任何在该机器 Secure
Boot policy 下可启动的代码都能触发 unseal。防的是磁盘拆走单独解密、
policy 篡改、TPM 清空；不防"本机启动任意签名系统"。密码 keyslot
永远是最终兜底。

Artifact 布局：

```text
/persist/system/tpm2/state.scm      enrollment 元数据（原子写 + .prev）
/persist/system/tpm2/objects/       sealed blobs 管理副本
ESP /EFI/Guix/tpm2/                 【解锁前读取】seal.pub/priv/metadata.scm
```

解锁 LUKS 前必须读取的数据不能只放 `/persist/system`（循环依赖）；
sealed blob 非秘密（不含明文），放 ESP，篡改只造成 DoS → 密码回退。

Enrollment 时点：Secure Boot 已启用（SecureBoot==1 且非 SetupMode）
并完成一次带最终 NVRAM policy 的正常启动后。enrollment 流程：
preflight → 验证 recovery 密码 → 生成 32 字节随机 credential → 读
当前 PCR7 → trial PolicyPCR → create sealed → unseal 自验证 →
luksAddKey 独立 keyslot → 新 keyslot 验证 → 发布 ESP artifact（失败
回滚 luksKillSlot）→ /persist 副本 + 原子写 state。`replace` 先加新
keyslot 再发布，绝不先删旧；recovery keyslot 永不触碰。

recovery 密码来源三选一（互斥；`enroll`/`replace` 都支持，
`status`/`preflight` 拒绝）：
- 交互读取（默认，tty 关闭回显）；
- `--luks-secret`：stable S 解密 `secrets/install/luks-recovery.age`
  （需先 `secrets unlock`；identity 缺失或解密失败立即中止，不静默
  回退交互；plaintext 不进 argv/env/log/store）；
- `--noninteractive`：stdin 直读一行。

来源解析统一走 `(guixcfg security credential-source)`——与
disk-install 的 `apply --luks-secret` 共享同一个 resolver，两个入口
不允许出现第二份实现（second implementation 一律改为调用它）。

initrd 解锁：cmdline 门控（recovery / guixcfg.tpm-unlock=0）→
/dev/tpmrm0 → 分区发现 → 挂 ESP → 读 seal 材料 → 确定性 SRK →
load sealed → policy session → unseal → 管道直连 cryptsetup
`--key-file=-`（明文不落盘/argv/env）→ 失败打印一行原因 → 密码回退。

## 内核模块签名

Secure Boot 开启后 lockdown 拒绝未签名外部模块。目标：外部模块在
安装/变更时用本项目 Secure Boot 密钥自签名，签名成为 system
generation 构建/部署的一部分，随 generation 部署与回滚。

**当前未实现**。Laptop 组装最终 NVIDIA 配置前必须实现并验证；不是
VM Secure Boot 的 blocker。

## 实测知识（tpm2-tools 5.7 / swtpm）

- tcti-swtpm 无 resource manager：测试环境每命令后
  `tpm2_flushcontext -t`（只 flush transient）；生产 /dev/tpmrm0
  由内核 RM 回收，禁止全局 flush。
- `tpm2_policypcr` 指定期望值用 `-f <pcrread 原始输出>` + `-l
  bank:index`；前向封印在 swtpm TCTI 下 0x1C4。
- `cryptsetup --key-file=-` 是读到 EOF 语义：passphrase 字节必须
  精确一致；luksAddKey 无法双 stdin。
- swtpm 测试必须用宿主 tpm2-tools（store 包不带 tcti-swtpm 插件）。
- initrd 模块闭包不能引入 (guix gexp)/(guix utils)（strverscmp
  dlsym，guile-static-initrd 无法解析）；kind 定义在 config 侧，
  initrd 只带运行时模块。
