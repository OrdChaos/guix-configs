#!/usr/bin/env bash
# T2 loopback LUKS 集成测试：swtpm + 真实 tpm2-tools + 真实 cryptsetup。
#
# 覆盖（PCR7-only）：
#   T2-1  PCR7=A enroll → unseal → LUKS credential 解锁        → PASS
#   T2-2  PCR7 改变 → unseal 失败 → recovery 密码解锁          → PASS
#   T2-3  sealed blob 损坏 → unseal 失败 → recovery 密码解锁    → PASS
#   T2-4  fresh swtpm（TPM clear）→ 旧 blob 无法 unseal
#        → recovery 密码解锁                                    → PASS
#   T2-5  Recovery 门控（不调 TPM 的判定）→ 密码解锁            → PASS
#        （纯逻辑判定已由 tests/test-tpm-unlock.scm 覆盖；
#          真实 rootmode=recovery cmdline 由 T3 VM 场景覆盖）
#
# 与生产路径一致的关键点：
#   - credential 经 stdin（--new-keyfile=- / --key-file=-），不落盘；
#   - unseal stdout 直接管道进 cryptsetup（与 initrd 相同）；
#   - luksAddKey 用户密码经 0600 临时文件（cryptsetup --key-file=-
#     是读到 EOF 语义，无法与 --new-keyfile=- 共享 stdin，实测）；
#   - 解锁验证用 --test-passphrase（无需 root、不建 mapping）。
#
# 用法：tools/test-tpm2-luks.sh
# 依赖：swtpm、tpm2-tools（含 libtss2-tcti-swtpm，宿主包）、
#       cryptsetup。

set -euo pipefail
cd "$(dirname "$0")/.."

command -v swtpm >/dev/null || { echo "swtpm missing" >&2; exit 1; }
command -v cryptsetup >/dev/null || { echo "cryptsetup missing" >&2; exit 1; }
# swtpm 测试必须用带 tcti-swtpm 插件的 tpm2-tools（宿主包；store 包不带）
TPM2_BIN=$(dirname "$(command -v tpm2_createprimary)" 2>/dev/null || true)
TPM2_BIN=${TPM2_BIN:-/usr/sbin}
[ -x "$TPM2_BIN/tpm2_createprimary" ] || { echo "tpm2-tools missing ($TPM2_BIN)" >&2; exit 1; }

W=/tmp/guixcfg-tpm2-luks-$$
PASS=0; FAIL=0
ok()   { echo "* PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "* FAIL: $1"; FAIL=$((FAIL+1)); }
run()  { "$@" >/dev/null 2>&1; }

RECOVERY_PW="t2-recovery-password"
# 32 字节随机 credential（hex，与 enroll 工具一致）
CRED=$(head -c 32 /dev/urandom | xxd -p -c 64)

start_swtpm() { # $1=state dir
    mkdir -p "$1"
    swtpm socket --tpm2 --tpmstate dir="$1" \
        --server type=unixio,path="$1/tpm.sock" \
        --ctrl type=unixio,path="$1/tpm.sock.ctrl" \
        --flags not-need-init,startup-clear --daemon
    for _ in $(seq 1 50); do
        [ -S "$1/tpm.sock" ] && break
        sleep 0.1
    done
    [ -S "$1/tpm.sock" ] || { echo "swtpm socket not ready" >&2; exit 1; }
}

stop_swtpm() { pkill -x swtpm 2>/dev/null || true; sleep 0.2; }

# direct swtpm 无 RM：每条命令后 scoped flush transient（实测 0x902）
flush_t() { run "$TPM2_BIN/tpm2_flushcontext" -t; }

cleanup() { stop_swtpm; rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W"
start_swtpm "$W/tpm"
export TPM2TOOLS_TCTI="swtpm:path=$W/tpm/tpm.sock"
cd "$W"

# ── 准备：file-backed LUKS 容器 + recovery 密码 keyslot ────
truncate -s 64M luks.img
printf '%s' "$RECOVERY_PW" | cryptsetup luksFormat --type luks2 \
    --batch-mode --key-file=- luks.img
printf '%s' "$RECOVERY_PW" | cryptsetup open --test-passphrase \
    --key-file=- luks.img \
    && ok "T2 setup: recovery passphrase keyslot usable" || bad "T2 setup: recovery passphrase keyslot unusable"

# ════════════════════════════════════════════════════════════
# T2-1：PCR7=A enroll → unseal → credential 解锁
# ════════════════════════════════════════════════════════════
run "$TPM2_BIN/tpm2_createprimary" -C o -G rsa2048 -g sha256 -c primary.ctx
run "$TPM2_BIN/tpm2_pcrread" sha256:7 -o pcr7.bin
run "$TPM2_BIN/tpm2_startauthsession" -S trial.ctx
run "$TPM2_BIN/tpm2_policypcr" -S trial.ctx -L policy.digest \
    -f pcr7.bin -l sha256:7
run "$TPM2_BIN/tpm2_flushcontext" trial.ctx
flush_t
POLICY_HEX=$(xxd -p -c 256 policy.digest)
printf '%s' "$CRED" | run "$TPM2_BIN/tpm2_create" -C primary.ctx \
    -u seal.pub -r seal.priv -L "$POLICY_HEX" -i - -g sha256
flush_t
run "$TPM2_BIN/tpm2_load" -C primary.ctx -u seal.pub -r seal.priv -c seal.ctx
flush_t

# luksAddKey：credential 经 stdin（--new-keyfile=-）；recovery 密码经 0600 临时文件
printf '%s' "$RECOVERY_PW" > pw.tmp && chmod 600 pw.tmp
printf '%s' "$CRED" | cryptsetup luksAddKey luks.img \
    --key-file=pw.tmp --new-keyfile=-
rm -f pw.tmp

# unseal stdout 管道 → cryptsetup --test-passphrase（与 initrd 相同路径）
run "$TPM2_BIN/tpm2_startauthsession" --policy-session -S sess.ctx
run "$TPM2_BIN/tpm2_policypcr" -S sess.ctx -l sha256:7
if "$TPM2_BIN/tpm2_unseal" -c seal.ctx -p session:sess.ctx \
        | cryptsetup open --test-passphrase --key-file=- luks.img; then
    ok "T2-1 PCR7=A -> unseal pipe -> LUKS credential unlock"
else
    bad "T2-1 PCR7=A -> unseal pipe -> LUKS credential unlock failed"
fi
run "$TPM2_BIN/tpm2_flushcontext" sess.ctx
flush_t

# ════════════════════════════════════════════════════════════
# T2-2：PCR7 改变 → unseal 失败 → 密码解锁
# ════════════════════════════════════════════════════════════
CHANGED=$(printf 'changed-policy' | sha256sum | cut -d' ' -f1)
run "$TPM2_BIN/tpm2_pcrextend" "7:sha256=$CHANGED"
run "$TPM2_BIN/tpm2_startauthsession" --policy-session -S sess2.ctx
run "$TPM2_BIN/tpm2_policypcr" -S sess2.ctx -l sha256:7
if "$TPM2_BIN/tpm2_unseal" -c seal.ctx -p session:sess2.ctx >/dev/null 2>&1; then
    bad "T2-2 PCR7 changed -> unseal should have failed"
else
    ok "T2-2 PCR7 changed -> unseal fails as expected"
fi
run "$TPM2_BIN/tpm2_flushcontext" sess2.ctx
flush_t
printf '%s' "$RECOVERY_PW" | cryptsetup open --test-passphrase \
    --key-file=- luks.img \
    && ok "T2-2 PCR7 changed -> recovery passphrase unlocks" || bad "T2-2 PCR7 changed -> recovery passphrase unlock failed"

# ════════════════════════════════════════════════════════════
# T2-3：sealed blob 损坏 → unseal 失败 → 密码解锁
# ════════════════════════════════════════════════════════════
cp seal.priv seal.priv.bak
dd if=/dev/urandom of=seal.priv bs=1 count=64 conv=notrunc 2>/dev/null
# 判定：损坏 blob 下 load（或 unseal）必须失败
if run "$TPM2_BIN/tpm2_load" -C primary.ctx -u seal.pub -r seal.priv -c seal2.ctx; then
    run "$TPM2_BIN/tpm2_startauthsession" --policy-session -S sess3.ctx
    run "$TPM2_BIN/tpm2_policypcr" -S sess3.ctx -l sha256:7
    if "$TPM2_BIN/tpm2_unseal" -c seal2.ctx -p session:sess3.ctx >/dev/null 2>&1; then
        bad "T2-3 corrupted blob -> unseal should have failed"
    else
        ok "T2-3 corrupted blob -> unseal fails as expected"
    fi
    run "$TPM2_BIN/tpm2_flushcontext" sess3.ctx
else
    ok "T2-3 corrupted blob -> load fails (equivalent to unseal failure)"
fi
flush_t
printf '%s' "$RECOVERY_PW" | cryptsetup open --test-passphrase \
    --key-file=- luks.img \
    && ok "T2-3 corrupted blob -> recovery passphrase unlocks" || bad "T2-3 corrupted blob -> recovery passphrase unlock failed"
cp seal.priv.bak seal.priv

# ════════════════════════════════════════════════════════════
# T2-4：TPM clear（fresh swtpm）→ 旧 blob 无法 unseal → 密码解锁
# ════════════════════════════════════════════════════════════
stop_swtpm
start_swtpm "$W/tpm-clear"
export TPM2TOOLS_TCTI="swtpm:path=$W/tpm-clear/tpm.sock"
run "$TPM2_BIN/tpm2_createprimary" -C o -G rsa2048 -g sha256 -c primary2.ctx
flush_t
run "$TPM2_BIN/tpm2_load" -C primary2.ctx -u seal.pub -r seal.priv -c seal3.ctx \
    || true
run "$TPM2_BIN/tpm2_startauthsession" --policy-session -S sess4.ctx
run "$TPM2_BIN/tpm2_policypcr" -S sess4.ctx -l sha256:7
if "$TPM2_BIN/tpm2_unseal" -c seal3.ctx -p session:sess4.ctx >/dev/null 2>&1; then
    bad "T2-4 TPM clear -> old blob should not unseal"
else
    ok "T2-4 TPM clear -> old blob cannot unseal"
fi
run "$TPM2_BIN/tpm2_flushcontext" sess4.ctx
flush_t
printf '%s' "$RECOVERY_PW" | cryptsetup open --test-passphrase \
    --key-file=- luks.img \
    && ok "T2-4 TPM clear -> recovery passphrase unlocks" || bad "T2-4 TPM clear -> recovery passphrase unlock failed"

# ════════════════════════════════════════════════════════════
# T2-5：Recovery 门控——不调 TPM 的路径 = 纯密码解锁
# （门控判定本身由 tests/test-tpm-unlock.scm 覆盖）
# ════════════════════════════════════════════════════════════
printf '%s' "$RECOVERY_PW" | cryptsetup open --test-passphrase \
    --key-file=- luks.img \
    && ok "T2-5 Recovery gated path (no TPM) -> passphrase unlock" \
    || bad "T2-5 Recovery gated path (no TPM) -> passphrase unlock failed"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
