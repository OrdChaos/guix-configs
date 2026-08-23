# Reconfigure

日常已安装系统的更新流程。安装见 `operations/installation.md`。

## 正式入口

```bash
sudo tools/reconfigure.sh        # 在仓库根目录运行
```

事务语义（gate 事务）：

```text
关闭 login gate（新 session 拒绝；已有 session 不动）
  → guix time-machine … system reconfigure
  → shepherd 升级自动 restart 变化的 one-shot 服务
    （runtime secrets 代际发布、account verify、Home 热激活）
  → 验证 Home 链接与 readiness capability 无 failed
  → 打开 gate
```

失败语义：

```text
reconfigure 失败          → gate 重开（无状态变化），exit 1
system 成功 + Home 失败   → gate 保持关闭，exit 2；
                            修复后重跑本脚本恢复（无需 reboot）
```

## 什么时候需要 reboot

- 内核/initrd/UKI 变化：boot 才生效。
- 纯 Shepherd 服务/activation 变化：reconfigure 热生效。
- gate 卡住（某 capability failed）：修复后重跑 reconfigure.sh，
  无需 reboot。

## 手动等价命令（configctl 可用前）

```bash
GUIX_CONFIG_FACTS=/persist/system/facts/host.scm \
  guix time-machine -C channels.lock.scm -- system reconfigure \
  -L "$PWD/modules" modules/guixcfg/hosts/vm.scm
```

日常验证：`guix system describe`、`herd status`、`guix home` 链接。

## 部署规则

- 正式部署只消费**已提交 Git commit 的只读快照**；脏工作区只能
  build 不能 switch。
- 频道更新显式执行：更新锁 → 构建 → 检查 → 提交 → switch。
- 运行时链接只指向 `/gnu/store`、`/run`、`/persist`，禁止指向仓库
  checkout。

## 频道管理

```text
channels.scm        频道集合与上游来源（Guix、Nonguix、Rosenthal、
                    personal-channel 按需）
channels.lock.scm   固定实际使用的 commit / introduction / branch
```

所有构建与部署经 `guix time-machine -C channels.lock.scm` 运行。
`system switch` / `home switch` 不能隐式更新频道。

**频道镜像与 substitutes 分离**：Git channel URL（获取源码）与
substitute URL（下载预构建 store item）配置分开；LiveCD 环境使用
代理。不需要的频道删除，不为"以后可能用"永久保留。

更新过程（显式、不可隐式）：

```text
更新 channel lock → 构建 → 检查 → 提交 → switch
```
