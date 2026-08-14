#!/usr/bin/env bash
# T3 clean-state 集成测试入口（tracked source）。
#
# 从 fresh workspace 建立并验证：
#   disk / VARS / swtpm / installation / Secure Boot / PCR7 enrollment /
#   A–E scenarios（A auto-unlock、B TPM clear fallback、C PCR7 change、
#   D Recovery、E corrupt artifact）。
#
# 职责边界：
#   tracked source —— 本目录（host.scm、boot.sh、fixtures/install-init）
#                     与 tools/（t7-e2e.sh、t7-interact.py、TPM/SB 工具）
#   runtime 产物  —— vms/t3/（qcow2、VARS、swtpm state、logs、临时 key、
#                     生成的 UKI，全部 gitignored）
#
# 用法：
#   tests/integration/t3/run.sh fresh          # 清理 runtime + SSH key + facts
#   tests/integration/t3/run.sh build-system  # 构建 T3 host system（SYSTEM_PATH）
#   tests/integration/t3/run.sh install       # 安装（t7-e2e.sh install）
#   tests/integration/t3/run.sh sb-keygen     # Secure Boot 密钥（宿主）
#   tests/integration/t3/run.sh sb-enroll     # Secure Boot enrollment（VM 内）
#   tests/integration/t3/run.sh enroll-tpm    # TPM enrollment（VM 内）
#   tests/integration/t3/run.sh scenario <name>  # A–E 场景
#   tests/integration/t3/run.sh all           # fresh → A–E 全流程
set -euo pipefail
cd "$(dirname "$0")/../../.."

export T7_DIR="$(pwd)/vms/t3"
export T7_INSTALL_DIR="$(pwd)/tests/integration/t3/fixtures"
ROOT="$(pwd)"

# 测试固定事实：安装器（fixtures/install-init）固定 LUKS UUID；
# machine facts 必须与磁盘事实一致（Phase 4 的核心不变量）。
LUKS_UUID="12345678-1234-1234-1234-123456789abc"
RECOVERY_PW="t7-recovery-password"   # 仅测试环境

SSH_OPTS=(-p 2222 -i "$T7_DIR/ssh/id_ed25519" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

usage() {
    sed -n 's/^#   /  /p' "$0" | grep -E "run.sh" | head -12
}

vm-ssh() {
    # sshd 依赖网络就绪（dhcpcd）与首次 host key 生成，root@guix-vm
    # 出现后可能仍需 1-2 分钟；连接失败（255）重试最多 2 分钟，
    # 命令失败（其他退出码）直接返回。
    local tries=0 rc=255
    while [ $rc -ne 0 ]; do
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 root@localhost "$@"
        rc=$?
        if [ $rc -eq 0 ]; then return 0; fi
        [ $rc -eq 255 ] || return $rc
        tries=$((tries+1))
        if [ $tries -ge 30 ]; then return 255; fi
        sleep 4
    done
}

gen-ssh-key() {
    mkdir -p "$T7_DIR/ssh"
    [ -f "$T7_DIR/ssh/id_ed25519" ] || \
        ssh-keygen -t ed25519 -N "" -q -f "$T7_DIR/ssh/id_ed25519"
}

fresh() {
    pkill -f 'qemu-system-x8[6]' 2>/dev/null || true
    pkill -x swtpm 2>/dev/null || true
    rm -rf "$T7_DIR"/{disk.qcow2,vars-*.fd,tpm-*,swtpm-*.sock,ssh,*.log,*.img,*.efi,mtoolsrc,os-release,system-path,requisites.txt,initramfs,facts.scm,keys}
    gen-ssh-key
    printf '((luks-uuid . "%s"))\n' "$LUKS_UUID" > "$T7_DIR/facts.scm"
    echo "fresh workspace 就绪（runtime: $T7_DIR）"
}

build-system() {
    GUIX_CONFIG_FACTS="$T7_DIR/facts.scm" \
        guix time-machine -C channels.lock.scm -- \
        system build -L modules -L tests \
        tests/integration/t3/host.scm | tee "$T7_DIR/system-path"
}

install() {
    [ -s "$T7_DIR/system-path" ] || build-system
    local sys="$(cat "$T7_DIR/system-path")"
    # 组装安装目录：init 脚本 tracked（fixtures/install-init）；内核模块
    # 是 runtime 产物（从系统内核 store 拷贝 virtio/9p/btrfs/dm-crypt 等）。
    local idir="$T7_DIR/install-files"
    rm -rf "$idir"; mkdir -p "$idir/modules"
    cp "$T7_INSTALL_DIR/install-init" "$idir/init"
    # readlink -f 解析到 linux 包目录下的 bzImage；内核模块在该目录的
    # lib/modules（一个 dirname 即可——两个 dirname 会退到 /gnu/store，
    # find 落空导致 install 提前退出）。
    local kdir="$(dirname "$(readlink -f "$sys/kernel/bzImage")")"
    find "$kdir/lib/modules" -name "*.ko.zst" 2>/dev/null \
        | grep -E "virtio|9p|btrfs|dm-crypt|blake2b|netfs|raid6|xor|nls" \
        | while read -r m; do cp "$m" "$idir/modules/"; done
    T7_INSTALL_DIR="$idir" SYSTEM_PATH="$sys" \
        timeout 1500 tools/t7-e2e.sh install
    echo "安装完成；下一步：sb-keygen → sb-enroll → enroll-tpm"
}

# Secure Boot 密钥：宿主生成（不依赖 VM），输出 vms/t3/keys/（gitignored）。
sb-keygen() {
    guix time-machine -C channels.lock.scm -- \
        shell -m manifests/secure-boot-keygen.scm -- \
        guix repl tools/secure-boot-keygen.scm "$T7_DIR/keys"
}

# Secure Boot enrollment：boot 无 SB 状态 → VM 内合并 keystore + sbkeysync。
# 此时尚无 TPM enrollment，磁盘需 recovery 密码解锁；T7_KEEP_VM=1
# 保持 VM 运行（interact 默认结束即关，后续 vm-ssh 无法连接）。
sb-enroll() {
    T7_KEEP_VM=1 tests/integration/t3/boot.sh interact sb-enroll \
        "wait:Enter passphrase|send:$RECOVERY_PW|wait:root@guix-vm" >/dev/null
    vm-ssh 'mkdir -p /mnt/cfg && mount -t 9p -o trans=virtio guix-configs /mnt/cfg && \
            cd /mnt/cfg && \
            guix time-machine -C channels.lock.scm -- shell -m manifests/secure-boot-enroll.scm -- \
              sh -c "guix repl tools/secure-boot-enroll.scm /mnt/cfg/vms/t3/keys && \
                     sbkeysync --keystore /mnt/cfg/vms/t3/keys/keystore --verbose && \
                     sbkeysync --keystore /mnt/cfg/vms/t3/keys/keystore --verbose --pk"'
    vm-ssh 'herd power-off root' >/dev/null 2>&1 || true
    sleep 8
    echo "Secure Boot enrollment 完成；重启验证 SecureBoot=1"
}

# TPM enrollment：boot（SB on）→ VM 内 tpm2-enroll。
enroll-tpm() {
    tests/integration/t3/boot.sh interact enroll-tpm "wait:root@guix-vm" >/dev/null
    vm-ssh 'mkdir -p /mnt/cfg && mount -t 9p -o trans=virtio guix-configs /mnt/cfg' 
    printf '%s\nyes\n' "$RECOVERY_PW" | vm-ssh \
        'cd /mnt/cfg && GUIXCFG_TPM_TCTI=device:/dev/tpmrm0 \
         guix repl tools/tpm2-enroll.scm -- enroll'
    vm-ssh 'herd power-off root' >/dev/null 2>&1 || true
    sleep 8
    echo "TPM enrollment 完成；重启后 Scenario A 验证自动解锁"
}

# 场景：boot + 交互 + 日志断言。
#   scenario A  自动解锁（无密码）
#   scenario B  TPM clear → 密码回退
#   scenario C  PCR7 change → 密码回退
#   scenario D  Recovery → TPM skip → 密码
#   scenario E  corrupt artifact → 密码回退
scenario() {
    local name="$1"
    case "$name" in
        A|a)
            T7_KEEP_VM=1 tests/integration/t3/boot.sh boot stage-b >/dev/null
            grep -a "TPM: LUKS 自动解锁成功" "$T7_DIR/interact-stage-b.log" >/dev/null \
                && echo "* A auto-unlock: PASS" || { echo "* A FAIL"; exit 1; }
            ;;
        B|b)
            tests/integration/t3/boot.sh fresh-tpm stage-b
            T7_KEEP_VM=1 tests/integration/t3/boot.sh interact stage-b \
                "wait:Enter passphrase|send:$RECOVERY_PW|wait:root@guix-vm" >/dev/null
            grep -a "回退密码" "$T7_DIR/interact-stage-b.log" >/dev/null \
                && echo "* B tpm-clear fallback: PASS" || { echo "* B FAIL"; exit 1; }
            ;;
        D|d)
            T7_KEEP_VM=1 tests/integration/t3/boot.sh interact stage-b \
                "wait:Enter passphrase|send:$RECOVERY_PW|wait:root@guix-vm" \
                -kernel "$T7_DIR/recovery-t3.efi" >/dev/null
            grep -a "tpm-skip" "$T7_DIR/interact-stage-b.log" >/dev/null \
                && ! grep -a "尝试自动解锁" "$T7_DIR/interact-stage-b.log" >/dev/null \
                && echo "* D recovery skip: PASS" || { echo "* D FAIL"; exit 1; }
            ;;
        E|e)
            vm-ssh 'cd /efi/EFI/Guix/tpm2 && printf "\x00" | dd of=seal.priv bs=1 seek=10 count=1 conv=notrunc 2>/dev/null; herd power-off root' >/dev/null 2>&1 || true
            sleep 8
            T7_KEEP_VM=1 tests/integration/t3/boot.sh interact stage-b \
                "wait:Enter passphrase|send:$RECOVERY_PW|wait:root@guix-vm" >/dev/null
            grep -a "尝试自动解锁" "$T7_DIR/interact-stage-b.log" >/dev/null \
                && grep -a "回退密码" "$T7_DIR/interact-stage-b.log" >/dev/null \
                && echo "* E corrupt artifact fallback: PASS" || { echo "* E FAIL"; exit 1; }
            ;;
        *) echo "未知场景: $name（A B D E）"; exit 1;;
    esac
}

all() {
    fresh
    build-system
    install
    sb-keygen
    sb-enroll
    enroll-tpm
    scenario A
    scenario B
    scenario D
    scenario E
}

case "${1:-}" in
    fresh) fresh;;
    build-system) build-system;;
    install) install;;
    sb-keygen) sb-keygen;;
    sb-enroll) sb-enroll;;
    enroll-tpm) enroll-tpm;;
    scenario) shift; scenario "$@";;
    all) all;;
    *) usage; exit 1;;
esac
