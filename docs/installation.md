# 安装流程与安全要求


---

# 30. 安装流程

## 30.1 LiveCD 仓库位置

临时 clone 到：

```text
/root/guix-configs
```

## 30.2 Bootstrap

使用锁定频道和 installer manifest：

```bash
guix time-machine \
  -C channels.lock.scm \
  -- shell \
  -m manifests/installer.scm \
  -- configctl install --host vm /dev/vda
```

注意：LiveCD 的根是内存盘，`/gnu/store` 也在内存里。磁盘安装完成、目标挂载到 `/mnt` 之后、执行任何 time-machine 或 `system init` 之前，必须先执行：

```bash
cow-store /mnt
```

把 store 转移到目标磁盘上，否则下载和构建会写满内存盘（低内存 VM 尤其如此）。

已验证的副作用：在 cow-store 环境下执行 `system init`，`/mnt/var/guix` 处于 bind 挂载的 busy 状态，init 无法将其替换为全新目录，导致系统 profile 注册（`/var/guix/profiles/system-N-link`）不落盘——首次启动后 `/etc/profile` 找不到系统 profile，PATH 残缺。因此**首次启动进入新系统后，应立即执行一次 `guix system reconfigure`**，让 profile 注册、bootcfg 生成和 bootloader 安装在正常环境下完整重做一遍。

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
→ guix system init
→ UKI / Limine
→ @root-template
→ @root-0
```

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
