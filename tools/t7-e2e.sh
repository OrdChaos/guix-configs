#!/usr/bin/env bash
# T7 完整 VM E2E：真实 Guix 系统（真实 initrd）+ OVMF + Secure Boot +
# swtpm + LUKS root。PCR7-only 版本（从 d832ef4 修剪：graft-kernel →
# ukify，去掉 PCR11 预测 / signed authorization / patch-cmdline）。
#
# 场景（docs/architecture/boot.md（TPM2），T3）：
#   auto-unlock      正常启动，TPM 自动解锁（无需密码）进入系统
#   secboot-off      Secure Boot 关闭 → PCR7 变化 → TPM fail → 密码回退
#   tpm-clear        fresh swtpm → 旧 blob 无法 unseal → 密码回退
#   corrupt          ESP 上 seal blob 被篡改 → 密码回退
#   recovery         RECOVERY.EFI（rootmode=recovery）→ 不调 TPM → 密码
#
# fixture（全部可重复）：vms/t7/{vars-*,tpm-*,disk.qcow2,keys}
#
# 用法：
#   SYSTEM_PATH=/gnu/store/xxx-system tools/t7-e2e.sh install
#   tools/t7-e2e.sh scenario <name>        # 场景启动（串口观察）
#   tools/t7-e2e.sh cleanup

set -euo pipefail

# 直接执行时 cd 到仓库根；被 source（如 vms/t3/t3-boot.sh）时保持调用方 cwd。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd "$(dirname "$0")/.."
fi

# T7_DIR 覆盖：T3 使用全新测试目录（vms/t3），避免污染旧 vms/t7 状态。
# 安装 initramfs 来源：T3 用 tests/integration/t3/fixtures（tracked 源码）；
# 旧 T7 流程沿用 vms/t7-install（历史遗留，非 git 源文件）。
T7="$(cd "${T7_DIR:-$(pwd)/vms/t7}" && pwd)"
T7_INSTALL_DIR="$(cd "${T7_INSTALL_DIR:-$(pwd)/vms/t7-install}" && pwd)"
STORE=/gnu/store
mkdir -p "$T7/keys" "$T7/tpm"

OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
# secboot 的 vars 模板与普通 VARS 相同（SMM 兼容性由 CODE.secboot 提供）
OVMF_VARS_SRC=/usr/share/edk2/x64/OVMF_VARS.4m.fd
[ -f "$OVMF_CODE" ] || OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.fd
[ -f "$OVMF_VARS_SRC" ] || OVMF_VARS_SRC=/usr/share/edk2/x64/OVMF_VARS.fd
DISK="$T7/disk.qcow2"

# ── 串口启动：每个场景独立 VARS / swtpm 状态 ────────────────
serial_boot() { # $1=name $2=log $3=timeout  [额外 qemu args...]
    local name="$1" log="$2" timeout_s="$3"; shift 3
    local vars="$T7/vars-$name.fd" tpmdir="$T7/tpm-$name"
    cp "$OVMF_VARS_SRC" "$vars"
    rm -rf "$tpmdir"; mkdir -p "$tpmdir"
    swtpm socket --tpm2 --tpmstate dir="$tpmdir" \
        --ctrl type=unixio,path="$T7/swtpm-$name.sock" --daemon
    for _ in $(seq 1 50); do [ -S "$T7/swtpm-$name.sock" ] && break; sleep 0.1; done
    # 串口交互：stdin 来自 FIFO（脚本发命令/密码），输出到日志
    local fifo="$T7/ctrl-$name.fifo"
    rm -f "$fifo"; mkfifo "$fifo"
    # 保持 FIFO 写端打开，避免 QEMU 因 stdin EOF 退出
    tail -f /dev/null > "$fifo" &
    local tpid=$!
    timeout "$timeout_s" qemu-system-x86_64 \
        -machine q35,accel=kvm,smm=on -m 4G -smp 2 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$vars" \
        -chardev socket,id=chrtpm,path="$T7/swtpm-$name.sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -device virtio-net-pci,netdev=n0 \
        -virtfs local,path="$PWD",mount_tag=guix-configs,security_model=mapped-xattr,id=cfg \
        "$@" \
        -display none -serial stdio -monitor none -no-reboot \
        < "$fifo" > "$log" 2>&1 || true
    kill "$tpid" 2>/dev/null || true
    rm -f "$fifo"
    pkill -x swtpm 2>/dev/null || true
}

# 向运行中的 VM 串口发送一行命令
serial_send() { # $1=name $2=命令
    printf '%s\n' "$2" > "$T7/ctrl-$1.fifo"
}

# 等待日志出现 PATTERN（最多 N 秒）
serial_wait() { # $1=log $2=pattern $3=timeout
    local log="$1" pattern="$2" t="$3" i=0
    while [ $i -lt "$t" ]; do
        grep -qa "$pattern" "$log" && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

usage() {
    echo "Usage: SYSTEM_PATH=/gnu/store/xxx-system tools/t7-e2e.sh install|scenario <name>|cleanup"
    exit 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
    install)
        # ── 组装安装 initramfs（busybox-static + 内核模块 + init）──
        # init 脚本：vms/t7-install/init（构造 GPT + LUKS2 + Btrfs，
        # 复制 closure、部署 UKI，见历史 era 的产物——该脚本本身不是
        # git 源文件，按需维护）
        BB=$(ls -d $STORE/*-busybox-static-*/bin 2>/dev/null | head -1)
        [ -n "$BB" ] || { echo "busybox-static missing" >&2; exit 1; }
        [ -n "${SYSTEM_PATH:-}" ] || { echo "SYSTEM_PATH required" >&2; exit 1; }
        [ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 25G
        rm -rf "$T7/initramfs"; mkdir -p "$T7/initramfs/bin" "$T7/initramfs/modules"
        cp "$T7_INSTALL_DIR/init" "$T7/initramfs/init"
        cp "$BB/busybox" "$T7/initramfs/bin/"
        for a in sh mount umount insmod cp mkdir cat echo sleep sync poweroff ls awk grep head mknod dmesg zcat basename dirname; do
            ln -sf busybox "$T7/initramfs/bin/$a"
        done
        # 模块预先解压（busybox zcat 不支持 zstd；insmod 不解压 .ko.zst）
        for m in "$T7_INSTALL_DIR"/modules/*.ko.zst; do
            [ -f "$m" ] || continue
            zstd -d -f "$m" -o "$T7/initramfs/modules/$(basename "$m" .zst)" 2>/dev/null
        done
        chmod +x "$T7/initramfs/init"
        (cd "$T7/initramfs" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$T7/install-initrd.img")

        # ── 构建安装 UKI（ukify 路线；kernel + 安装 initramfs）────
        UKIFY=$(ls -d $STORE/*-ukify-*/bin/ukify | head -1)
        STUB=$(ls -d $STORE/*-systemd-stub-*/libexec/linuxx64.efi.stub | head -1)
        [ -n "$UKIFY" ] && [ -n "$STUB" ] || { echo "ukify/systemd-stub missing" >&2; exit 1; }
        printf 'NAME="Guix System"\nID=guix\n' > "$T7/os-release"
        "$UKIFY" build --linux "$SYSTEM_PATH/kernel/bzImage" \
            --initrd "$T7/install-initrd.img" \
            --os-release "$T7/os-release" --cmdline "console=ttyS0" \
            --stub "$STUB" --output "$T7/install-uki.efi" 2>/dev/null

        # ── 引导盘（GPT + FAT + 安装 UKI 为 EFI/BOOT/BOOTX64.EFI）──
        MFORMAT=$(ls -d $STORE/*-mtools-*/bin/mformat | head -1)
        MTOOLS_BIN=$(dirname "$MFORMAT")
        SGDISK=$(ls -d $STORE/*-gptfdisk-*/bin/sgdisk | head -1)
        dd if=/dev/zero of="$T7/boot.img" bs=1M count=64 status=none
        "$SGDISK" -n 1:2048:0 -t 1:ef00 "$T7/boot.img" >/dev/null
        cat > "$T7/mtoolsrc" <<EOF
drive x: file="$T7/boot.img" offset=1048576
EOF
        export MTOOLSRC="$T7/mtoolsrc"
        "$MFORMAT" -F -v ESP x:
        "$MTOOLS_BIN/mmd" x:/EFI
        "$MTOOLS_BIN/mmd" x:/EFI/BOOT
        "$MTOOLS_BIN/mcopy" -o "$T7/install-uki.efi" x:/EFI/BOOT/BOOTX64.EFI

        # ── requisites 列表与系统路径（host 预生成）────────────────
        echo "$SYSTEM_PATH" > "$T7/system-path"
        cp -f "$T7/system-path" vms/system-path
        timeout 120 guix time-machine -C channels.lock.scm -- gc -R "$SYSTEM_PATH" \
            2>/dev/null | grep -vE "hint:|GUIX_LOCPATH|locale|Application|^$|warning: channel" \
            > "$T7/requisites.txt" || true
        if [ -s "$T7/requisites.txt" ]; then
            cp -f "$T7/requisites.txt" vms/requisites.txt
        fi

        # ── 启动安装（boot 盘 = 第一个 virtio，数据盘 = 第二个）────
        serial_boot install "$T7/install.log" 1200 \
            -drive file="$T7/boot.img",format=raw,if=none,id=boot0 \
            -device virtio-blk-pci,drive=boot0 \
            -drive file="$DISK",format=qcow2,if=none,id=hd0 \
            -device virtio-blk-pci,drive=hd0,serial=guix-t7-disk \
            -virtfs local,path="$STORE",mount_tag=gnu-store,security_model=none,id=st
        if grep -q "T7-INSTALL-DONE" "$T7/install.log"; then
            echo "* T7 install: PASS (disk construction + closure copy + UKI deployment done)"
        else
            echo "* T7 install: FAIL (see $T7/install.log)"
            grep -E "T7-INSTALL-FAIL|T7-INSTALL:|error" "$T7/install.log" | tail -8 || true
            exit 1
        fi
        ;;
    scenario)
        [ -n "${2:-}" ] || usage
        name="$2"
        serial_boot "$name" "$T7/scenario-$name.log" 600 \
            -drive file="$DISK",format=qcow2,if=none,id=hd0 \
            -device virtio-blk-pci,drive=hd0,serial=guix-t7-disk
        echo "scenario $name serial log: $T7/scenario-$name.log"
        ;;
    cleanup)
        pkill -x swtpm 2>/dev/null || true
        rm -rf "$T7"/vars-*.fd "$T7"/tpm-* "$T7"/swtpm-*.sock
        echo "cleaned"
        ;;
    *)
        usage
        ;;
esac
fi
