#!/usr/bin/env bash
# T3 场景驱动（tests/integration/t3/，tracked）：统一管理
# QEMU/VARS/swtpm 生命周期，用 t7-interact.py 做串口交互。
# runtime 产物（disk/VARS/swtpm/日志）在 vms/t3/（gitignored）。
#
# 用法：
#   export T7_DIR=vms/t3
#   boot.sh boot <name> [extra qemu args...]      # 用已有 vars/tpm（无则创建）
#   boot.sh fresh-vars <name>                     # 从模板重建 VARS
#   boot.sh fresh-tpm <name>                      # 重建 swtpm 状态
#   boot.sh interact <name> <script> [extra qemu args...]
#                                                  # boot + T7_SCRIPT 交互
set -euo pipefail
cd "$(dirname "$0")/../../.."

# t7-e2e.sh source 时会 cd（$0 仍是本脚本路径，dirname 解析到 tests/），
# 因此 T7_DIR 必须绝对路径，source 之后再 cd 回仓库根。
export T7_DIR="${T7_DIR:-$(pwd)/vms/t3}"
source tools/t7-e2e.sh   # 提供 T7/OVMF 常量；不调用其 serial_boot
cd "$(pwd)"

T3SOCK=""

start_swtpm_for() { # $1=name —— 复用已有 TPM 状态（permall）或全新
    local tpmdir="$T7/tpm-$1" sock="$T7/swtpm-$1.sock"
    # 同一时刻只有一个 VM：先清掉旧 swtpm 与 stale socket，
    # 再按状态目录决定复用（permall 存在）或全新。
    pkill -x swtpm 2>/dev/null || true
    sleep 0.3
    rm -f "$sock"
    if [ ! -d "$tpmdir" ] || [ ! -f "$tpmdir/tpm2-00.permall" ]; then
        rm -rf "$tpmdir"
        mkdir -p "$tpmdir"
    fi
    # 输出必须静默：qemu_args 经 $(...) 捕获，swtpm 的 stdout
    # 混入会污染 QEMU 参数（实测 "Could not open 'stdio'"）。
    swtpm socket --tpm2 --tpmstate dir="$tpmdir" \
        --ctrl type=unixio,path="$sock" --daemon >/dev/null 2>&1
    # 等 socket 真正可连接（QEMU 是 client 立即连接，失败即退出）。
    for _ in $(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('$sock'); s.close()" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    T3SOCK="$sock"
}

qemu_args() { # $1=name [extra...]——输出 qemu 参数
    local name="$1"; shift
    local vars="$T7/vars-$name.fd"
    [ -f "$vars" ] || cp "$OVMF_VARS_SRC" "$vars"
    start_swtpm_for "$name"
    echo -machine q35,accel=kvm,smm=on -m 4G -smp 2 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$vars" \
        -chardev socket,id=chrtpm,path="$T3SOCK" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -device virtio-net-pci,netdev=n0 \
        -virtfs local,path="$PWD",mount_tag=guix-configs,security_model=mapped-xattr,id=cfg \
        "$@" \
        -display none -serial @STDIO@ -monitor none -no-reboot
}

interact() { # $1=name $2=script [extra qemu args...]
    local name="$1" script="$2"; shift 2
    T7_SCRIPT="$script" T7_LOG="$T7/interact-$name.log" \
        timeout 1200 python3 tools/t7-interact.py \
        $(qemu_args "$name" -drive file="$DISK",format=qcow2,if=none,id=hd0 \
                    -device virtio-blk-pci,drive=hd0,serial=guix-t7-disk "$@")
    if [ -z "${T7_KEEP_VM:-}" ]; then
        pkill -x swtpm 2>/dev/null || true
    fi
}

case "${1:-}" in
    interact) shift; interact "$@";;
    boot)     shift; name="$1"; shift
              T7_SCRIPT="wait:root@guix-vm" T7_LOG="$T7/interact-$name.log" \
                  timeout 1200 python3 tools/t7-interact.py \
                  $(qemu_args "$name" -drive file="$DISK",format=qcow2,if=none,id=hd0 \
                              -device virtio-blk-pci,drive=hd0,serial=guix-t7-disk "$@")
              if [ -z "${T7_KEEP_VM:-}" ]; then
                  pkill -x swtpm 2>/dev/null || true
              fi;;
    fresh-vars) shift; rm -f "$T7/vars-$1.fd";;
    fresh-tpm)  shift; rm -rf "$T7/tpm-$1" "$T7/swtpm-$1.sock";;
    *) echo "用法: $0 interact|boot|fresh-vars|fresh-tpm"; exit 1;;
esac
