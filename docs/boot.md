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

## 16.4 TPM2

### 兼容性与边界

Guix System 可以使用 TPM2，但当前项目不把它视为 Guix 原生的一等公民功能：
Guix 提供 `tpm2-tools` 等基础组件，LUKS 仍由项目自定义 initrd 控制。也就是说，
TPM 自动解锁应实现为 initrd 的一个受控解锁路径，而不是要求 systemd 作为 PID 1。

目标：

```text
正常启动
  TPM policy 满足 → 自动解锁 LUKS
                  ↓ 失败/TPM 不可用
                密码回退

Recovery
  强制跳过 TPM 自动解锁 → 手工密码
```

要求：

- TPM enrollment 在完整系统安装完成后执行；
- 永远保留独立的密码 keyslot，不让 TPM 成为唯一恢复路径；
- TPM 使用独立随机 LUKS credential/keyslot，不直接把 LUKS volume key 当作
  项目管理的普通文件；
- Recovery 明确禁用 TPM 自动解锁；
- TPM 清空、主板更换、Secure Boot policy 改变后都可以用密码进入并重新
  enrollment。

### PCR policy

当前 UKI 使用 `systemd-stub`，即使 Guix System 以 Shepherd 而不是 systemd
作为 init，stub 仍会在进入内核前把 UKI 的相关 PE section 度量到 **PCR 11**。
因此不能再假设“Guix 没有 systemd，所以没有 PCR11 UKI measurement”。

目标策略：

```text
PCR7
  固件 Secure Boot policy / authority 处于预期状态
+
PCR11 signed policy
  当前 UKI 内容属于本项目 policy key 授权的版本
=
允许 TPM 自动解锁
```

不把 TPM 永久密封到某一个固定 PCR11 值。由独立 PCR policy signing key 对每次
部署 UKI 的预期 PCR11 policy 签名，更新系统时只生成新的签名 policy，而无需
重新 enrollment TPM。`ukify` / `systemd-measure` / `systemd-stub` 的 PCR policy
机制可以独立于 systemd PID 1 使用。

### enrollment 数据放置

**解锁 LUKS 之前必须读取的数据不得只放在 `/persist/system`**，因为
`@persist-system` 本身就在该 LUKS 容器内部，否则会形成循环依赖。

优先边界：

```text
解锁前需要：
  TPM sealed/encrypted credential + token metadata
      → 优先放 LUKS2 JSON token/header
      → 或必要时放 ESP / TPM NV
  PCR policy public material/signature
      → UKI / LUKS2 token / ESP 中的公开材料

解锁后管理：
  PCR policy signing private key
  enrollment 版本、审计信息、重新 enrollment 状态
      → /persist/system/keys/tpm/ 与 /persist/system/tpm/
```

TPM sealed blob 本身不依赖保密性，但必须考虑篡改导致的拒绝服务；私有 policy
signing key 只在解锁后可见，不进入 ESP、Git 或 `/gnu/store`。

实现状态：**阶段 5.5，尚未实现自动解锁代码**。`tools/test-vm.sh --secboot`
已经提供 swtpm TPM2 测试设备。TPM enrollment/initrd 实现时再引入独立的
`tpm2-tools` 依赖，不把 TPM 工具链耦合进早期磁盘 installer manifest。

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
