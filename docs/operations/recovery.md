# Recovery

LiveCD 救援流程。系统坏了从这里开始。

> 底层工具是恢复/诊断的权威入口，保留手工能力（Blue install/enroll
> 的失败恢复也落到这里）：`disk-install inspect/plan`、
> `secrets unlock/verify/decrypt`、`secure-boot-keygen/enroll`、
> `tpm2-enroll preflight/status/enroll/replace`。安装中途失败的
> resume 语义见 `installation.md`（`blue install` 重跑自动跳过已完成
> 阶段，绝不自动重新格式化）。

## 日常回滚（无需 LiveCD）

- **Recovery**：boot 菜单（Limine）选择 `GNU Guix (Recovery)`。
  恢复 previous confirmed boot pair（last-good root + 与之配对的
  system generation），重新经过完整 readiness 链（不绕过
  barrier）。公开 boot model 只有 Normal / Recovery 两项；历史
  @root 不作为菜单项（磁盘保留由清理服务管理，见
  docs/architecture/boot.md）。
- **secrets 恢复**：master password → `tools/secrets.scm unlock` →
  原 ciphertext 无 rekey 即可解密（stable S 模型）。
- **密码/账户恢复**：provision 新 hash（见安装 阶段 7）或直接编辑
  `/persist/system/accounts/<user>/password.hash`（root）。

## LiveCD 救援

```bash
# 1. 挂载仓库
mkdir -p /root/src && mount -t 9p -o trans=virtio guix-configs /root/src
cd /root/src

# 2. 解锁 LUKS（TPM 失败时密码回退）
cryptsetup open /dev/vda2 cryptroot
# 若 TPM 自动解锁：正常 boot 即可；LiveCD 救援需人工

# 3. 挂 Btrfs 顶层（subvolid=5），检查 root generations
mkdir -p /mnt/top
mount -t btrfs -o subvolid=5 /dev/mapper/cryptroot /mnt/top
btrfs subvol list /mnt/top

# 4. 挂载持久子卷 + 选中的 @root-N
mount -t btrfs -o subvol=@persist-system /dev/mapper/cryptroot /mnt/persist-system
mount -t btrfs -o subvol=@root-N /dev/mapper/cryptroot /mnt/root

# 5. 检查状态文件
cat /mnt/persist-system/root-generations/state.scm
# 修复/检查 boot-state
cat /mnt/persist-system/boot-states.scm
```

### chroot 注意事项

- 只读检查尽量不 chroot；需要 chroot 时先 bind：
  ```bash
  mount --bind /gnu/store /mnt/root/gnu/store
  mount --bind /proc /mnt/root/proc
  mount --bind /dev /mnt/root/dev
  mount --bind /sys /mnt/root/sys
  chroot /mnt/root /bin/sh
  ```
- 修正后 umount 全部、`sync`、halt。

### boot state recovery

- root generation 状态损坏：`read-state` 自动回退 `.prev`。
- Recovery 入口：`RECOVERY.EFI`（rootmode=recovery）→ 不调 TPM →
  人工密码 → last-good Guix generation + last-good root。
- 若 boot-status 卡在 trying：正常完成一次图形登录即自动恢复
  （confirm 挂在 greetd PAM session open——登录成功本身就是确认
  信号），或重跑 reconfigure。

## 密码 keyslot 永远存在

TPM 清空、主板更换、Secure Boot policy 改变后：密码 keyslot 始终
可用 → 密码进入 → 重新 `tpm2-enroll replace`。
