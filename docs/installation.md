# 安装流程与安全要求


---

# 30. 安装流程

## 30.1 LiveCD 仓库位置

通过 9p 共享挂载（VM）或 clone 到：

```text
/root/guix-configs
```

## 30.2 Bootstrap

当前没有 configctl；安装命令是直接的 `guix repl` / `guix system` 调用。
LiveCD 环境（VM 内）：

```bash
mkdir -p /root/src && mount -t 9p -o trans=virtio guix-configs /root/src && cd /root/src
```

注意：LiveCD 的根是内存盘，`/gnu/store` 也在内存里。磁盘安装完成、目标挂载到 `/mnt` 之后、执行任何 time-machine 或 `system init` 之前，必须先执行：

```bash
herd start cow-store /mnt
```

把 store 转移到目标磁盘上，否则下载和构建会写满内存盘（低内存 VM 尤其如此）。安装器在磁盘安装结束时会检测 `/gnu/store` 是否仍在 tmpfs 上，是则醒目提醒执行这一步。

cow-store 环境下 `system init` 的另一个坑：init 会先 `delete-file-recursively` 删除目标的 `/var/guix` 重新开始注册，而挂载点删不掉（EBUSY）。因此 **`@persist-var-guix` 在 init 期间刻意不挂载**（`mount-at-install? #f`），让 `/var/guix` 以普通目录建在 `@root-installing` 里——init 看到的是完全原生的环境，profile 注册、store 数据库全部正常落盘。安装期提交（`commit-root`）在快照之前把这份内容收进 `@persist-var-guix` 子卷，模板里留下空目录作运行时挂载点。

## 30.3 安装阶段

```text
检查目标设备
→ 显示磁盘信息
→ 验证目标未挂载
→ 验证不是 LiveCD 系统盘
→ 验证容量
→ 打印完整 plan
→ 要求输入完整设备路径确认
→ GPT
→ ESP
→ LUKS2
→ Btrfs
→ 持久子卷
→ swapfile
→ @root-installing
→ 挂载 /mnt
→ guix system init（含 UKI/Limine 部署）
→ commit-root（收养 /var/guix → @root-template/@root-0 → 初始状态
   → 重跑部署刷新 ESP 菜单）
→ （可选）Secure Boot 密钥与固件注册
```

### 30.3.1 磁盘安装

```bash
guix shell gptfdisk cryptsetup btrfs-progs dosfstools util-linux -- \
  guix repl tools/disk-install.scm -- apply vm /dev/vda
```

### 30.3.2 系统安装

```bash
herd start cow-store /mnt
GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm \
  guix time-machine -C channels.lock.scm -- system init \
  -L modules modules/guixcfg/hosts/vm.scm /mnt
```

init 末尾会运行 UKI 部署脚本（生成 UKI、Limine 配置与 fallback）。
此时 ESP 菜单只有 `GNU Guix` 一项：root 状态文件要 `commit-root`
才写、last-good 要第一次健康启动才有——零历史时的正确形态。

### 30.3.3 安装期提交

```bash
guix repl tools/disk-install.scm -- commit-root /mnt
```

依次执行：收养 `/var/guix` 进 `@persist-var-guix` → 快照固化
`@root-template` / `@root-0` → 删除 `@root-installing` → 写初始
root generation 状态（`first-boot`，原子写）→ **重跑 UKI 部署**，
让 ESP 菜单立即带上 Previous 项。然后：

```bash
swapoff -a && umount -R /mnt && reboot
```

首次启动由 initrd 里的无状态根逻辑接管。菜单语义见 docs/boot.md
第 16.1 节；`rootmode=` 参数见 docs/storage.md 第 17.6 节。

### 30.3.4 Secure Boot（可选，实机建议先无 Secure Boot 验证一轮）

```bash
# 生成密钥（LiveCD 内，目标盘的 /persist/system/keys/secure-boot/）
guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm -- \
  guix repl tools/secure-boot-keygen.scm /mnt/persist/system/keys/secure-boot

# 构建合并 keystore（自有 + 微软证书 + 固件默认值）
guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm -- \
  guix repl tools/secure-boot-enroll.scm /mnt/persist/system/keys/secure-boot

# 注册进固件（Setup Mode；PK 最后写，写入即启用）
guix time-machine -C channels.lock.scm -- shell -m manifests/installer.scm -- sh -c '
  sbkeysync --keystore /mnt/persist/system/keys/secure-boot/keystore --verbose &&
  sbkeysync --keystore /mnt/persist/system/keys/secure-boot/keystore --verbose --pk'
```

密钥存在后，每次部署（init/reconfigure）自动用 db 密钥签 UKI 与
Limine。信任模型与 OpROM 注意事项见 docs/boot.md 第 16.3 节。

## 30.4 仓库复制

安装完成前，把同一 Git commit 部署到：

```text
/mnt/persist/data-home/<user>/guix-configs
```

目标系统中暴露为：

```text
~/guix-configs
```

正式安装默认拒绝脏工作区。

## 30.5 安装记录

保存：

```text
配置 Git revision
channel revisions
目标 host
安装时间
磁盘设备
生成的 UUID
安装器版本
```

位置：

```text
/persist/system/install/
```
