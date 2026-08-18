#!/usr/bin/env bash
# 测试 VM：Guix 安装 ISO + 空白 qcow2 数据盘 + 仓库目录 9p 共享。
# UEFI 启动（OVMF），本项目只支持 UEFI。
#
# 用法（从仓库根目录）：
#   tools/test-vm.sh [--secboot] /path/to/guix-system-install-x86_64-linux.iso   # 从 ISO 启动（安装）
#   tools/test-vm.sh [--secboot]                                                 # 从硬盘启动
#
#   --secboot   Secure Boot 能力的 OVMF（OVMF_CODE.secboot）+ swtpm 虚拟 TPM2，
#               使用独立的 VARS（vms/OVMF_VARS.secboot.fd），不影响开发 VM。
#
# ISO 下载：https://guix.gnu.org/download/ （选 "GNU Guix System on ... installer"）
#
# VM 内操作：
#   1. 共享目录挂载：  mkdir -p /root/src && mount -t 9p -o trans=virtio guix-configs /root/src
#   2. 进入仓库：      cd /root/src
#   3. 查看计划：      guix repl tools/disk-install.scm -- plan vm /dev/vda
#   4. 执行安装：      guix repl tools/disk-install.scm -- apply vm /dev/vda
#   5. 系统安装：      guix time-machine -C channels.lock.scm -- system init \
#                        -L modules -e '(@ (guixcfg hosts vm) %os)' /mnt
#
# 图形后端：显式 VirGL 3D——-device virtio-vga-gl + -display gtk,gl=on
# （QEMU virtio-gpu docs / Niri 官方 VM 建议；guest 看到带 3D 加速的
# virtio-gpu）。virtio-vga-gl 需要宿主 QEMU 带 virglrenderer 构建：
# 启动前检测（-device help），缺失则明确报错，不静默降级——降级会
# 掩盖 3D 能力问题。无图形环境（无 DISPLAY/WAYLAND_DISPLAY）退回
# -nographic + -vga virtio（无 display 后端就没有 GL 上下文）。
#
# 数据盘是 virtio（/dev/vda）。注意两点（已查证）：
# - by-id/virtio-* 链接要求磁盘有非空 serial，所以下面用 -device virtio-blk-pci
#   显式指定 serial=guix-test-disk，安装器的 by-id 校验才能通过；
# - eudev 的 path_id 不支持 virtio 子系统，by-path 对 virtio 盘永远不会生成。

# 正常关机（不要直接 Ctrl-C 杀 QEMU，等于拔电源）：
#   1. guest 内 reboot / poweroff；或
#   2. 主机上发 ACPI 电源键事件（guest 收到后走正常关机流程）：
#      python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("vms/monitor.sock"); s.sendall(b"system_powerdown\n")'

set -euo pipefail

SECBOOT=0
if [ "${1:-}" = "--secboot" ]; then
    SECBOOT=1
    shift
fi

ISO=${1:-}
IMG=vms/test-disk.qcow2
if [ "$SECBOOT" = 1 ]; then
    VARS=vms/OVMF_VARS.secboot.fd
else
    VARS=vms/OVMF_VARS.fd
fi

mkdir -p vms
if [ ! -f "$IMG" ]; then
    echo "Creating blank data disk $IMG (25G)"
    qemu-img create -f qcow2 "$IMG" 25G
fi

# ── OVMF 固件 ──────────────────────────────────────────────
# CODE 只读、VARS 每 VM 一份可写副本（Secure Boot 变量也存这里）。
if [ "$SECBOOT" = 1 ]; then
    OVMF_CODE=""
    for p in /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
             /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd \
             /usr/share/OVMF/OVMF_CODE.secboot.fd; do
        if [ -f "$p" ]; then OVMF_CODE="$p"; break; fi
    done
    [ -n "$OVMF_CODE" ] || { echo "OVMF_CODE.secboot not found (install edk2-ovmf)" >&2; exit 1; }
    # secboot 变体的认证变量存储在 SMM 里：缺了这两个参数，
    # 任何 UEFI 变量写入都会被固件拒绝（Invalid argument）。
    MACHINE=q35,smm=on
    PFLASH_SECURE=(-global driver=cfi.pflash01,property=secure,value=on)
else
    OVMF_CODE=""
    for p in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
             /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/qemu/OVMF_CODE.fd; do
        if [ -f "$p" ]; then OVMF_CODE="$p"; break; fi
    done
    [ -n "$OVMF_CODE" ] || { echo "OVMF_CODE not found (install edk2-ovmf)" >&2; exit 1; }
    MACHINE=q35
    PFLASH_SECURE=()
fi

if [ ! -f "$VARS" ]; then
    OVMF_VARS=""
    for p in "${OVMF_CODE%CODE*}VARS.4m.fd" \
             "${OVMF_CODE%CODE*}VARS.fd" \
             /usr/share/edk2/x64/OVMF_VARS.4m.fd \
             /usr/share/OVMF/OVMF_VARS.fd; do
        if [ -f "$p" ]; then OVMF_VARS="$p"; break; fi
    done
    [ -n "$OVMF_VARS" ] || { echo "OVMF_VARS not found" >&2; exit 1; }
    cp "$OVMF_VARS" "$VARS"
fi

FIRMWARE=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
          -drive if=pflash,format=raw,file="$VARS")

# ── TPM2（仅 --secboot 模式，swtpm 虚拟 TPM）────────────────
TPM=()
if [ "$SECBOOT" = 1 ]; then
    command -v swtpm >/dev/null || { echo "swtpm not found (install it)" >&2; exit 1; }
    mkdir -p vms/tpm
    rm -f vms/swtpm-sock
    swtpm socket --tpm2 --tpmstate dir=vms/tpm \
        --ctrl type=unixio,path=vms/swtpm-sock --daemon
    TPM=(-chardev socket,id=chrtpm,path=vms/swtpm-sock
         -tpmdev emulator,id=tpm0,chardev=chrtpm
         -device tpm-tis,tpmdev=tpm0)
fi

# ── 启动介质 ───────────────────────────────────────────────
BOOT=()
if [ -n "$ISO" ]; then
    BOOT=(-cdrom "$ISO" -boot d)
fi

# 有 KVM 用 KVM，没有则退回 TCG（慢，但磁盘安装测试够用）。
ACCEL=()
if [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
fi

# ── 图形后端：显式 VirGL 3D ─────────────────────────────────
# 有图形环境用 gtk,gl=on + virtio-vga-gl（guest 获 VirGL 3D）；
# 否则退回串口终端（-nographic，-vga virtio 不变）。
GPU_ARGS=(-vga virtio)
DISPLAY_ARGS=(-display gtk)
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if qemu-system-x86_64 -device help 2>/dev/null | grep -qw virtio-vga-gl; then
        GPU_ARGS=(-device virtio-vga-gl)
        DISPLAY_ARGS=(-display gtk,gl=on)
    else
        echo "host qemu-system-x86_64 has no virtio-vga-gl (built without virglrenderer)" >&2
        echo "install a virgl-enabled QEMU, e.g. Arch 'qemu-desktop'/'qemu-full'; verify with:" >&2
        echo "  qemu-system-x86_64 -device help | grep virtio-vga-gl" >&2
        exit 1
    fi
else
    DISPLAY_ARGS=(-nographic)
fi

# LiveCD 的 root 是内存盘，重启即消失，所以每次进 VM 都要重新挂载共享目录。
# 启动前把这行打印出来，方便直接复制粘贴到 VM 里：
cat <<'EOF'
--------------------------------------------------------------------
Once the VM is up, paste this line into the guest (mounts the repo share):

  mkdir -p /root/src && mount -t 9p -o trans=virtio guix-configs /root/src && cd /root/src

Then (guix shell provides tools missing from the ISO, e.g. sgdisk):
  guix shell gptfdisk cryptsetup btrfs-progs dosfstools util-linux -- \
    guix repl tools/disk-install.scm -- apply vm /dev/vda
  (deliberately no time-machine here: disk-install only needs the early
   storage/policies deps and must not load Rosenthal/Nonguix; switch
   /gnu/store to the target disk before entering the locked channels.)

After disk install, move the store onto the target disk first (LiveCD
/gnu/store lives in RAM; running time-machine/system init directly
would fill it):
  herd start cow-store /mnt

Install the system (note: init does not accept -e; use the host file
directly -- the bare %os at its end makes it a valid entry point.
GUIX_CONFIG_FACTS points at the machine facts file on the target disk):
  GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm \
    guix time-machine -C channels.lock.scm -- system init \
    -L modules modules/guixcfg/hosts/vm.scm /mnt

Then commit the install-time root:
  guix repl tools/disk-install.scm -- commit-root /mnt
--------------------------------------------------------------------
EOF

exec qemu-system-x86_64 \
    -machine "$MACHINE" "${ACCEL[@]}" -m 8G -smp 2 \
    "${GPU_ARGS[@]}" \
    "${PFLASH_SECURE[@]}" \
    "${FIRMWARE[@]}" \
    "${TPM[@]}" \
    -drive file="$IMG",if=none,id=hd0,format=qcow2 \
    -device virtio-blk-pci,drive=hd0,serial=guix-test-disk \
    "${BOOT[@]}" \
    -virtfs local,path="$PWD",mount_tag=guix-configs,security_model=mapped-xattr,id=cfg \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=n0 \
    -monitor unix:vms/monitor.sock,server=on,wait=off \
    "${DISPLAY_ARGS[@]}"
