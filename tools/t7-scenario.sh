#!/usr/bin/env bash
# T7 场景驱动（PCR7-only）：启动已安装 VM，通过串口交互执行场景。
# 用法: tools/t7-scenario.sh auto-unlock|secboot-off|tpm-clear|corrupt|recovery
# 依赖 t7-e2e.sh 的 serial_* 函数（source）。
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/t7-e2e.sh

SCEN="${1:?scenario name required: auto-unlock|secboot-off|tpm-clear|corrupt|recovery}"
export MTOOLSRC="$T7/mtoolsrc"

# 场景启动：所有场景共享同一磁盘（enrollment 状态持久在磁盘 /persist）
case "$SCEN" in
    secboot-off)
        # 关闭 Secure Boot：用普通 OVMF CODE（非 secboot）+ 普通 VARS。
        # PCR7 因此不同 → unseal 失败 → 密码回退
        OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
        OVMF_VARS_SRC=/usr/share/edk2/x64/OVMF_VARS.4m.fd
        ;;
    tpm-clear)
        # 全新 swtpm 状态（模拟 TPM clear）：serial_boot 会重建 tpm-$SCEN
        rm -rf "$T7/tpm-$SCEN"
        ;;
    corrupt)
        # 篡改 ESP 上的 sealed blob（seal.priv 损坏）
        # 在启动前用 mtools 改写 ESP EFI/Guix/tpm2/seal.priv
        cp "$OVMF_VARS_SRC" "$T7/vars-$SCEN.fd"
        dd if=/dev/urandom of="$T7/bad-seal.bin" bs=1 count=64 status=none
        MTOOLSRC="$T7/mtoolsrc" "$MTOOLS_BIN/mcopy" -o "$T7/bad-seal.bin" \
            x:/EFI/Guix/tpm2/seal.priv 2>/dev/null || \
            echo "(corrupt scenario needs tpm2 materials first; skipping tamper if absent)"
        ;;
    recovery)
        # Recovery：把 RECOVERY.EFI（内置 rootmode=recovery）作为
        # 引导盘 BOOTX64.EFI 启动——initrd 看到 rootmode=recovery，
        # 不调用 TPM，直接密码路径。RECOVERY.EFI 来自活动槽。
        MFORMAT=$(ls -d $STORE/*-mtools-*/bin/mformat | head -1)
        MTOOLS_BIN=$(dirname "$MFORMAT")
        SGDISK=$(ls -d $STORE/*-gptfdisk-*/bin/sgdisk | head -1)
        dd if=/dev/zero of="$T7/recovery-boot.img" bs=1M count=64 status=none
        "$SGDISK" -n 1:2048:0 -t 1:ef00 "$T7/recovery-boot.img" >/dev/null
        cat > "$T7/mtoolsrc" <<EOF
drive x: file="$T7/recovery-boot.img" offset=1048576
EOF
        export MTOOLSRC="$T7/mtoolsrc"
        "$MFORMAT" -F -v ESP x:
        "$MTOOLS_BIN/mmd" x:/EFI
        "$MTOOLS_BIN/mmd" x:/EFI/BOOT
        # 从数据盘 ESP 提取 RECOVERY.EFI（活动槽；A/B 任一）
        (MTOOLSRC="$T7/mtoolsrc" "$MTOOLS_BIN/mcopy" -o x:/EFI/Guix/A/RECOVERY.EFI "$T7/recovery.efi" 2>/dev/null) || \
            (MTOOLSRC="$T7/mtoolsrc" "$MTOOLS_BIN/mcopy" -o x:/EFI/Guix/B/RECOVERY.EFI "$T7/recovery.efi" 2>/dev/null) || \
            { echo "RECOVERY.EFI not found on ESP (run reconfigure first)" >&2; exit 1; }
        "$MTOOLS_BIN/mcopy" -o "$T7/recovery.efi" x:/EFI/BOOT/BOOTX64.EFI
        # 用普通 VARS（Recovery 不依赖 Secure Boot 状态）
        OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
        OVMF_VARS_SRC=/usr/share/edk2/x64/OVMF_VARS.4m.fd
        ;;
    auto-unlock)
        # 默认：secboot OVMF + 现有 VARS/swtpm 状态重建。
        # 注意：serial_boot 会重建 vars-$SCEN.fd 与 tpm-$SCEN——
        # 首次跑会得到全新 swtpm（PCR7 从 0 开始），此时应配合
        # TPM enrollment 流程（见 docs/architecture/boot.md）；enrollment 后的
        # 再次启动才验证自动解锁。
        cp "$OVMF_VARS_SRC" "$T7/vars-$SCEN.fd" 2>/dev/null || true
        ;;
esac

BOOT_ARGS=()
if [ "$SCEN" = "recovery" ]; then
    BOOT_ARGS=(-drive file="$T7/recovery-boot.img",format=raw,if=none,id=boot0 \
               -device virtio-blk-pci,drive=boot0)
fi

serial_boot "$SCEN" "$T7/scenario-$SCEN.log" 600 \
    "${BOOT_ARGS[@]}" \
    -drive file="$DISK",format=qcow2,if=none,id=hd0 \
    -device virtio-blk-pci,drive=hd0,serial=guix-t7-disk

echo "=== scenario $SCEN serial log: $T7/scenario-$SCEN.log"
