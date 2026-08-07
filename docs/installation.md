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
