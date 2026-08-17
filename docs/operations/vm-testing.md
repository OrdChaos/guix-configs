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

- `tools/t7-e2e.sh` + `tools/t7-scenario.sh`：OVMF Secure Boot +
  swtpm + 签名 UKI 场景（auto-unlock / secboot-off / tpm-clear /
  corrupt / recovery）。
- `tools/test-tpm2-poc.sh`：swtpm PolicyPCR 机制（seal/unseal、
  extend 后失败）。
- `tools/test-tpm2-luks.sh`：真实 cryptsetup 回退场景。

这些是历史 E2E harness；新功能开发优先用 Level 1-4 测试（见
`development/testing.md`）。
