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
签名 UKI（ESP/EFI/Guix/*.EFI，efi_chainload）
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
GNU Guix (Recovery)   last-good 系统 + last-good root
                      （两轴一起回退；无确认记录时不出现）
```

实现分层（GCD006 重写 Guix bootloader 框架时只需改适配层）：

```text
boot/uki-bootloader.scm   框架适配层（唯一依赖 <bootloader>/<menu-entry>）
boot/uki.scm              deploy-core：<boot-plan> + 部署脚本生成
boot/boot-state.scm       Boot State 注册表（Guix 轴的 last-good）
```

部署是事务式的：新 UKI 全部就位后才更新 Limine 配置与 fallback；
`.deployed` 清单只清理我们自己部署过的文件，ESP 上的其他内容不碰。

## 16.2 UKI

- 工具链：Rosenthal 频道的 `systemd-stub` + `ukify`（锁定在
  channels.lock.scm）。不依赖 systemd 作为 init/service manager。
- 组装在部署期进行（init/reconfigure）：部署脚本（Guix
  configuration-file 机制产出的 program-file）以 root 运行 ukify。
- UKI 命名固定（`CURRENT.EFI` 等），历史选择靠 initrd 的
  `rootmode=previous:K` 相对选择器，菜单永不因启动轮转而过期。
- Recovery UKI 的数据源是 `/persist/system/boot-states.scm`
  注册表——**部署成功 ≠ 启动成功**，注册表只由用户态确认服务更新。

## 16.3 Secure Boot

信任模型（实机策略）：自有 PK/KEK/db + 微软兼容证书 + 固件默认值。

```text
PK    只有我们自己的（平台所有权归本机）
KEK   我们的 KEK + Microsoft KEK CAs + 固件 KEKDefault
db    我们的 db + Microsoft db CAs（含 Option ROM UEFI CA 2023，
      显卡 OpROM 需要）+ 固件 dbDefault
```

- 密钥生成：`tools/secure-boot-keygen.scm`（ukify genkey），
  产出到 `/persist/system/keys/secure-boot/`（0700/0400，
  不进 Git、不进 /gnu/store）；已存在拒绝覆盖。
- 微软证书：`(guixcfg security certificates)`，origin + 固定 sha256，
  经 store 取用；固件默认值经 `efi-readvar` 现读。
- 注册材料：`tools/secure-boot-enroll.scm` 合并出 sbkeysync
  keystore（`{PK,KEK,db}/*.auth`），注册用 sbkeysync 执行
  （PK 最后写，写入即启用）。
- 签名在部署期：部署脚本探测到 `db.key`/`db.crt` 即用 sbsign
  签 UKI 与 Limine；密钥不存在则全部不签（开发期）。
- 重装默认生成新的信任材料（删除旧密钥目录后重新 keygen）。

## 16.4 TPM2

目标：

```text
TPM 自动解锁 LUKS
        ↓ 不可用
密码回退
```

要求：

- TPM enrollment 在完整系统安装完成后执行；
- 不删除密码解锁路径；
- Secure Boot 状态变化后可重新 enrollment；
- 恢复模式必须支持手工密码。

实现方向（阶段 5.5，未做）：PCR7（Secure Boot 状态）策略密封卷密钥，
initrd 的 pre-mount 先尝试 TPM 解封再回退密码。不绑 PCR11
（无 systemd-stub 度量 UKI；PCR7 在系统更新间不变，免去每次
reconfigure 重 enroll）。

## 16.5 内核模块签名

Secure Boot 开启后内核进入 lockdown，未签名的外部内核模块（如 NVIDIA 专有模块）会被拒绝加载。因此：

- 外部内核模块在安装时和每次变更后均使用本项目 Secure Boot 密钥自签名；
- 签名是系统部署流程的一部分，与 UKI 签名同一密钥体系；
- 使用 `sbsign`/`kmodsign` 的自定义部署步骤（sbctl 不在 Guix 频道）；
- 签名后的模块随 system generation 一起部署和回滚，不手工对运行中系统补签。

该项与 NVIDIA 配置（见第 24 章）强相关，必须在 Laptop 实机启用 Secure Boot 前完成验证。
