#!/usr/bin/env bash
# T1 PoC：swtpm + 真实 tpm2-tools 的 PCR7 PolicyPCR 完整语义验证。
#
# 用例（全部用真实 tpm2-tools，无 mock）：
#   PCR7=A + 匹配 policy → unseal 成功
#   PCR7 改变（extend）  → unseal 失败（TPM 拒绝 policy）
#
# 这里测试的是 TPM PolicyPCR 机制本身（PCR 用 swtpm 的人工状态），
# 不是完整 OVMF Secure Boot 集成（那是 T2/T3 的事）。
#
# 用法：tools/test-tpm2-poc.sh
# 依赖：swtpm、tpm2-tools（含 libtss2-tcti-swtpm）。

set -euo pipefail
cd "$(dirname "$0")/.."

command -v swtpm >/dev/null || { echo "swtpm missing" >&2; exit 1; }

# swtpm 测试必须用带 tcti-swtpm 插件的 tpm2-tools：store 中的
# tpm2-tools（生产 /dev/tpmrm0 用）不带该插件，走宿主系统包。
TPM2_BIN=$(dirname "$(command -v tpm2_createprimary)" 2>/dev/null || true)
TPM2_BIN=${TPM2_BIN:-/usr/sbin}
[ -x "$TPM2_BIN/tpm2_createprimary" ] || { echo "tpm2-tools missing ($TPM2_BIN)" >&2; exit 1; }

W=/tmp/guixcfg-tpm2-poc-$$
mkdir -p "$W/tpm"
cleanup() { pkill -x swtpm 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT

# fresh swtpm（PCR 从 0 开始，无任何持久对象）
swtpm socket --tpm2 --tpmstate dir="$W/tpm" \
    --server type=unixio,path="$W/tpm.sock" \
    --ctrl type=unixio,path="$W/tpm.sock.ctrl" \
    --flags not-need-init,startup-clear --daemon
# --daemon 返回后 socket 可能尚未创建，等它就绪
for _ in $(seq 1 50); do
    [ -S "$W/tpm.sock" ] && break
    sleep 0.1
done
[ -S "$W/tpm.sock" ] || { echo "swtpm socket not ready" >&2; exit 1; }

# 测试环境：direct swtpm TCTI 无 resource manager，需要 scoped
# flush transient objects（tpm2-tools.scm 头注释的实测结论）
export TPM2TOOLS_TCTI="swtpm:path=$W/tpm.sock"
cd "$W"

PASS=0; FAIL=0
ok()   { echo "* PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "* FAIL: $1"; FAIL=$((FAIL+1)); }
run()  { "$@" >/dev/null 2>&1; }

# ── 1. SRK ───────────────────────────────────────────────────
run "$TPM2_BIN/tpm2_createprimary" -C o -G rsa2048 -g sha256 -c primary.ctx \
    && ok "createprimary (SRK)" || bad "createprimary (SRK)"

# ── 2. 读 PCR7，做 trial PolicyPCR digest（sha256:7）────────
run "$TPM2_BIN/tpm2_pcrread" sha256:7 -o pcr7.bin \
    && ok "pcrread sha256:7" || bad "pcrread sha256:7"
PCR7_A=$(xxd -p -c 256 pcr7.bin)
run "$TPM2_BIN/tpm2_startauthsession" -S trial.ctx
# -f 期望值文件 + -l bank:index（-l "bank:index=值" 前向封印在 swtpm 下 0x1C4）
run "$TPM2_BIN/tpm2_policypcr" -S trial.ctx -L policy.digest -f pcr7.bin -l sha256:7 \
    && ok "trial PolicyPCR (-f expected value)" || bad "trial PolicyPCR (-f expected value)"
run "$TPM2_BIN/tpm2_flushcontext" trial.ctx
run "$TPM2_BIN/tpm2_flushcontext" -t

# ── 3. seal 一个固定 secret（经 stdin，不落盘明文）──────────
printf 'tpm-poc-secret-0123456789abcdef' > secret.txt
POLICY_HEX=$(xxd -p -c 256 policy.digest)
printf 'tpm-poc-secret-0123456789abcdef' | \
    run "$TPM2_BIN/tpm2_create" -C primary.ctx -u seal.pub -r seal.priv \
        -L "$POLICY_HEX" -i - -g sha256 \
    && ok "create sealed object (-L hex, stdin secret)" \
    || bad "create sealed object (-L hex, stdin secret)"
# direct swtpm 无 RM：每条命令的 ContextLoad 都占新 transient slot，
# 不 flush 会 0x902（见 tpm2-tools.scm 头注释的实测结论）
run "$TPM2_BIN/tpm2_flushcontext" -t

# ── 4. PCR7=A 匹配：真实 policy session unseal 成功 ─────────
run "$TPM2_BIN/tpm2_load" -C primary.ctx -u seal.pub -r seal.priv -c seal.ctx \
    && ok "load sealed object" || bad "load sealed object"
run "$TPM2_BIN/tpm2_flushcontext" -t
run "$TPM2_BIN/tpm2_startauthsession" --policy-session -S sess.ctx
run "$TPM2_BIN/tpm2_policypcr" -S sess.ctx -l sha256:7
if "$TPM2_BIN/tpm2_unseal" -c seal.ctx -p session:sess.ctx -o unsealed.bin \
        && cmp -s secret.txt unsealed.bin; then
    ok "PCR7=A matches -> unseal succeeds with identical content"
else
    bad "PCR7=A matches -> unseal should have succeeded with identical content"
fi
run "$TPM2_BIN/tpm2_flushcontext" sess.ctx

# ── 5. extend PCR7（模拟 Secure Boot policy 变化）───────────
CHANGED=$(printf 'changed-policy' | sha256sum | cut -d' ' -f1)
run "$TPM2_BIN/tpm2_pcrextend" "7:sha256=$CHANGED" \
    && ok "pcrextend 7 (PCR7 changed)" || bad "pcrextend 7 (PCR7 changed)"
NEW_PCR7=$("$TPM2_BIN/tpm2_pcrread" sha256:7 -o - 2>/dev/null | xxd -p -c 256 || true)
if [ -n "$NEW_PCR7" ] && [ "$NEW_PCR7" != "$PCR7_A" ]; then
    ok "PCR7 value actually changed"
else
    bad "PCR7 value did not change ($PCR7_A vs $NEW_PCR7)"
fi

# ── 6. PCR7 已变：unseal 必须失败 ───────────────────────────
run "$TPM2_BIN/tpm2_startauthsession" --policy-session -S sess2.ctx
run "$TPM2_BIN/tpm2_policypcr" -S sess2.ctx -l sha256:7
if "$TPM2_BIN/tpm2_unseal" -c seal.ctx -p session:sess2.ctx -o x.bin >/dev/null 2>&1; then
    bad "PCR7 changed -> unseal should have failed"
else
    ok "PCR7 changed -> unseal fails as expected"
fi
run "$TPM2_BIN/tpm2_flushcontext" sess2.ctx
run "$TPM2_BIN/tpm2_flushcontext" -t

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
