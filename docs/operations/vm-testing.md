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

## E2E / TPM 场景

- `tools/t7-e2e.sh` + `tools/t7-scenario.sh`：OVMF Secure Boot +
  swtpm + 签名 UKI 场景（auto-unlock / secboot-off / tpm-clear /
  corrupt / recovery）。
- `tools/test-tpm2-poc.sh`：swtpm PolicyPCR 机制（seal/unseal、
  extend 后失败）。
- `tools/test-tpm2-luks.sh`：真实 cryptsetup 回退场景。

这些是历史 E2E harness；新功能开发优先用 Level 1-4 测试（见
`development/testing.md`）。
