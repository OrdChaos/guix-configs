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
→ guix system init
→ UKI / Limine
→ @root-template
→ @root-0
```

其中「@root-template → @root-0」即安装期提交（docs/storage.md 第 17.3 节），
在 `guix system init` 成功之后、卸载 `/mnt` 之前执行：

```bash
guix repl tools/disk-install.scm -- commit-root /mnt
```

它把 `@root-installing` 固化为只读 `@root-template` 和可写 `@root-0`，
并写入初始 root generation 状态（`first-boot`）。提交后首次启动
由 initrd 里的无状态根逻辑接管：Normal 模式每次启动从模板新建
`@root-N`；内核命令行 `rootmode=keep[:N]` / `rootmode=recovery`
可复用指定 generation 或回退到 last-good。

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
