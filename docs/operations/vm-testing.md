# VM Testing

测试 VM 的启动、安装、E2E 流程。QEMU 硬件细节在此，
不放进 architecture。

## 启动 VM

```bash
# 从 ISO 启动（安装）
tools/test-vm.sh --secboot /path/to/guix-system-install-x86_64-linux.iso
# 从硬盘启动
tools/test-vm.sh --secboot
```

`--secboot` 模式：Secure Boot OVMF（OVMF_CODE.secboot.4m.fd）+
swtpm 虚拟 TPM2，独立 VARS（vms/OVMF_VARS.secboot.fd）。

硬件约定：

- 数据盘 virtio（`/dev/vda`），serial=guix-test-disk（by-id 校验）；
- 25 GiB qcow2（`vms/test-disk.qcow2`）；
- host 2222 → guest 22 转发；
- 9p 共享 `guix-configs` → 仓库根（`mount -t 9p -o trans=virtio
  guix-configs /root/src`）；
- monitor: `vms/monitor.sock`；串口：`-nographic` 或
  `-serial unix:vms/serial.sock`（自动化用）。

## SSH 进 LiveCD

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p 2222 root@127.0.0.1
```

## 正常关机

```bash
# guest 内
/run/current-system/profile/sbin/halt
# 或 host monitor
python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.connect("vms/monitor.sock");s.sendall(b"system_powerdown\n")'
```

不要 Ctrl-C 杀 QEMU（等于拔电源）。

## Fresh install 测试

完整流程见 `operations/installation.md`，在 VM 内执行。自动化时可
用串口 socket + python 驱动，或先 SSH bootstrap 再 ssh 执行。

## Fresh install core baseline acceptance checklist

首次安装完成、`commit-root` 已执行、重启进入系统后，逐项验收
（Level 5 的“能启动”的最低可观测集合；第二次冷启动重复全部条目）：

1. **root generation state sanity**
   `/persist/system/root-generations/state.scm` 可解析、字段齐全：
   首次启动后 `boot-status` 由 `first-boot` 推进（trying → 确认后
   `ok`）；`current`/`last-good` 指向实际存在的 `@root-N` 子卷
   （`btrfs subvolume list /` 交叉验证）；`next` 单调。
2. **/run/user/1000 absent/present 语义**
   登录（SSH 或 tty）前 `/run/user/1000` 不存在；登录后由 elogind
   创建，权限 0700，owner 1000；登出后删除（无残留）。
3. **Guix Home links**
   `~/.guix-home` 是指向当前 generation 的 symlink（readlink 到
   `/gnu/store/...-home`）；无 `~/.guix-home.new` pivot 残留；重新
   login 后 `guix home` 投影内容可见（如 shell 配置生效）。
4. **persistent dirs 为 bind mounts**
   `findmnt` 确认 `/persist/system`、`/persist/data-app`、
   `/persist/data-home` 等是 Btrfs 子卷挂载、`/gnu/store`、
   `/var/guix` 是 bind mount；`/etc` 由 ephemeral root 投影而非
   独立持久化（无重复 writer）。
5. **/etc/shadow verifier == persistent hash**
   `/etc/shadow` 中用户的 password 字段与
   `/persist/system/accounts/<user>/password.hash` 内容完全一致；
   `account-databases-verify` 服务 succeeded（`herd status`）。
6. **失败 readiness boot 不得 promote Last Good**
   篡改（如破坏 `/persist/system/accounts/<user>/password.hash`
   或 shadow verifier 校验路径）后重启：readiness 链失败、login
   gate 关闭，且 `boot-state` 的 last-good **不被** promote（保持
   上次确认值）；修复后重启恢复。这是 fail-closed 语义的整机级
   验证（Level 3 只证明单程序，这里证明 boot 时序）。
7. **第二次冷启动重复检查**
   clean 重启（不篡改）后重复 1-5 全部条目——验证幂等与持久化
   在无干预启动下的稳定性。

## E2E / TPM 场景

- 当前活入口：`tests/integration/t3/`（run.sh + boot.sh + fixtures），
  经 `tools/t7-e2e.sh`（install 与 QEMU 常量）与 `tools/t7-interact.py`
  （串口交互）驱动 OVMF Secure Boot + swtpm + 签名 UKI 场景
  （A auto-unlock / B tpm-clear / C PCR7 change / D recovery /
  E corrupt）。
- 历史 harness（保留、不维护、无调用者）：`tools/t7-scenario.sh`
  （已被 t3/run.sh 自带的 scenario 取代）、`tools/test-tpm2-poc.sh`
  （swtpm PolicyPCR 机制 PoC）、`tools/test-tpm2-luks.sh`（真实
  cryptsetup 回退场景——tests/ 内尚无 Level 1-4 等价覆盖）。

新功能开发优先用 Level 1-4 测试（见 `development/testing.md`）。

## 光标异常排查记录（2026-08-29，已结案）

**症状**（VM 内，virtio GPU）：

1. greeter 内光标**倒置**（上下颠倒，UI 其余部分正常）；
2. 登录成功后 greeter 光标**不消失**，在 niri 里与真实光标**一起
   跟随鼠标移动**，二者有**固定位置差**，且 niri 光标才对得上
   点击位置（幽灵光标 = 硬件 cursor plane 上的陈旧 buffer）。

**结论**：宿主 **virglrenderer** 的 bug（virtio-gpu 的 GL 宿主侧
渲染后端对 cursor plane 的 buffer 上传/移交处理错误），与 greeter、
wlroots、noctalia 无关。guest 侧无法修复；已回滚全部 greeter 侧
cursor patch，channel 恢复 unpatched 上游状态。

**排查路径**（供后续对照）：

1. **先证伪交付，再怀疑逻辑**。最初怀疑 virelith channel 的
   cursor 修复未生效：`nm -D` 检查 VM 里正在运行的
   noctalia-greeter-compositor 二进制，补丁符号为 0。但 **VM 里
   没有安装 `nm`**——命令静默失败、空输出被 grep 计成 0，得出了
   "补丁没编译进去"的假结论。改用 `grep -a` 直接扫二进制的
   .dynstr 后确认补丁符号其实**都在**（教训：验证符号存在性时，
   先确认工具本身存在；`command -v` 先行）。
2. **gen 46 vs gen 47**。gen 46（substitute* 版修复）的 greeter
   二进制确实没有补丁符号——substitute* 是**逐行匹配**
   （`read-line` + `list-matches` 单行内匹配），跨多行的 pattern
   **永不匹配**，且该 Guix 版本的 substitute* 在 pattern 不匹配时
   **不报错**——phase "succeeded" 但一个字节没改。这是"构建成功 ≠
   补丁生效"的典型陷阱。gen 47（patch 文件版）修复已真实编译进
   二进制，但症状依旧 → 说明 patch 治的不是这个病。
3. **软件光标 vs 硬件光标的本质**。wlroots 每个 output 有
   `software_cursor_locks` 计数（`WLR_NO_HARDWARE_CURSORS=1` 在
   output 初始化时置 1）：
   - **硬件光标**（默认）：`render_cursor_buffer` 把光标渲染进
     独立小 buffer，经独立 KMS **cursor plane** 叠加——不走主
     framebuffer；
   - **软件光标**：`output_cursor_attempt_hardware` 直接返回
     false，光标被 composite 进**主 framebuffer**，与场景同一条
     渲染/变换管线。
   两个症状恰好都是硬件 cursor plane 的固有风险：倒置 = 独立
   plane 的 buffer 取向与主内容不一致；幽灵 = 独立 plane 状态跨
   compositor 交接泄漏（niri 接手后驱动自己的光标平面，陈旧
   buffer 挂在其上一起移动 → 跟随鼠标 + 固定偏移 + 点击对不上）。
   这也解释了 A/B 实验里 `WLR_NO_HARDWARE_CURSORS=1` 为何全好。
4. **错误的假设性 patch（已回滚）**。先做了 orientation patch
   （假设倒置来自 panel orientation 未合成；但 VM 是 virtio、
   rotation=0、panel orientation=NORMAL，条件永不成立）；再做
   teardown patch（假设幽灵是退出时未禁用的静态残留 plane；但
   幽灵跟随鼠标，说明是 niri 正在驱动的 plane 装着旧 buffer，
   退出时禁用解决不了）。最终强制软件光标 patch 等价于环境变量，
   虽可消除症状，但掩盖的是宿主侧根因——已按用户确认真实根因
   （virglrenderer）后全部回滚。
5. **回滚动作**（2026-08-29）：virelith commit `ed57562`
   （"revert(noctalia-greeter): drop compositor cursor patches"，
   以用户签名后的 commit 为准）将 noctalia-greeter 恢复为
   unpatched 上游状态；channels.lock.scm 的 virelith 指向该
   回滚提交。

**VM 硬件层教训**：VM 显示异常（光标倒置/幽灵、GL 渲染错乱）
优先怀疑宿主 QEMU GL 后端（virglrenderer）版本与 guest Mesa 的
组合，而不是 guest 侧 compositor——guest 侧补丁只能掩盖症状。

