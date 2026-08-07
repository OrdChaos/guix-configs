# 启动：Secure Boot、UKI 和 TPM


---

# 16. Secure Boot、UKI 和 TPM

## 16.1 Bootloader

不使用 GRUB。

目标启动结构：

```text
UEFI
  ↓
Limine 菜单
  ↓
签名 UKI
  ↓
initrd
  ↓
LUKS2
  ↓
Btrfs root generation
```

同时保留：

```text
固件直接启动 UKI
```

作为回退路径。

## 16.2 UKI

目标：

- 每个系统 generation 生成对应 UKI；
- UKI 放入 ESP；
- reconfigure 后更新；
- 旧 generation 保留可启动能力；
- 不依赖 systemd 作为 init/service manager。

具体 UKI 生成实现需要在 VM 阶段验证。

## 16.3 Secure Boot

目标：

- 安装时生成新的 Secure Boot 密钥；
- 私钥不进入 Git；
- 私钥保存在 `/persist/system/keys/secure-boot/` 或离线介质；
- UKI 和必要的 EFI 程序必须签名；
- 固件注册流程由安装器明确执行；
- 重装默认生成新的信任材料。

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

## 16.5 内核模块签名

Secure Boot 开启后内核进入 lockdown，未签名的外部内核模块（如 NVIDIA 专有模块）会被拒绝加载。因此：

- 外部内核模块在安装时和每次变更后均使用本项目 Secure Boot 密钥自签名；
- 签名是系统部署流程的一部分，与 UKI 签名同一密钥体系；
- 优先评估 `sbctl` 管理密钥和签名；若 `sbctl` 在 Guix/Shepherd 环境下不可用或不合适，再评估替代方案（如直接使用 `sbsign`/`kmodsign` 的自定义 activation），并在实现前更新本节；
- 签名后的模块随 system generation 一起部署和回滚，不手工对运行中系统补签。

该项与 NVIDIA 配置（见第 24 章）强相关，必须在 Laptop 实机启用 Secure Boot 前完成验证。
