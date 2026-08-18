#!/bin/sh
# reconfigure orchestration（docs/operations/reconfigure.md 的 configctl system switch
# 在 VM 阶段的最小实现；configctl 全套——git 干净检查/只读快照/部署记录——
# 仍是规划中的未来工作）。
#
# 职责：system reconfigure + 成功后热激活绑定的 Guix Home + readiness
# gate 事务语义（docs/architecture/accounts-sessions.md J8）：
#
#   close gate（新 interactive session 被拒；已有 session 不动）
#     → guix system reconfigure
#     → shepherd 升级自动 restart 变化的 one-shot 服务（secrets 代际
#       发布、password 投影、Home 热激活）
#     → 验证：Home 链接状态 + 各 readiness capability 无 failed
#     → open gate
#
# 为什么需要显式热激活验证（错误语义见 docs/architecture/accounts-sessions.md
# J5）：`guix system reconfigure` 的服务升级对 one-shot 服务是
# fire-and-forget：shepherd 把 activate 进程 fork 出去即视为成功——
# Home activate 失败（如 ~/.guix-home 被非空目录阻塞、或上次失败残留
# 的 ~/.guix-home.new pivot）不会反馈到 reconfigure 退出码。这里在
# reconfigure 成功后显式 restart + 验证链接状态，失败时明确报告。
#
# 错误语义：
#   1. system reconfigure 失败   → exit 1，Home 完全不动，gate 重新打开
#      （system 没变，没有新的不一致）；
#   2. system 成功 + Home 失败   → exit 2，明确报告 system 已切换、
#      Home 热激活失败；不回滚 system；**gate 保持关闭**（新 session
#      拒绝）直到人工修复后重新运行本脚本（或 herd restart 各服务 +
#      删 gate）恢复。
#
# 用法（root）：tools/reconfigure.sh [host]   # host 默认 vm
# 环境变量：HOME_USER 指定 Home 绑定用户（默认 user）。

set -eu

HOST="${1:-vm}"
HOME_USER="${HOME_USER:-user}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="/run/guixcfg/session-not-ready"
cd "$ROOT"

# ── 0. 关闭 gate：新 interactive session 被拒；已有 session 不动 ──
mkdir -p /run/guixcfg
printf 'A reconfigure is in progress.\n' > "$GATE"

old_link=""
if [ -L "/home/$HOME_USER/.guix-home" ]; then
  old_link="$(readlink "/home/$HOME_USER/.guix-home")"
fi

# 1. system reconfigure（失败则 Home 完全不动、gate 重新打开）
if ! guix time-machine -C channels.lock.scm -- system reconfigure \
       "modules/guixcfg/hosts/$HOST.scm" -L modules; then
  rm -f "$GATE"
  echo "reconfigure: system reconfigure FAILED; Home left untouched;" >&2
  echo "  gate reopened (no state changed)." >&2
  exit 1
fi

# 2. Home 热激活（幂等：home closure 未变时 activate 重建同一组链接）
#
#    preflight：上次失败激活的 stale pivot（~/.guix-home.new）会让
#    activate 的 (symlink new-home pivot) 永久 EEXIST（上游不处理残留）。
#    保守清理：home-pivot.scm 只 unlink 指向 store home generation 的
#    symlink；普通文件/目录/未知 symlink fail closed（明确报错退出）。
pivot="/home/$HOME_USER/.guix-home.new"
if ! guile -L "$ROOT/modules" -s "$ROOT/tools/home-pivot.scm" \
       --clean "$pivot" >/dev/null 2>&1; then
  echo "reconfigure: stale pivot $pivot exists but is NOT a recognizable" >&2
  echo "  Guix Home pivot symlink (plain file/directory/unknown link);" >&2
  echo "  refusing to touch it. Investigate manually, then retry." >&2
  echo "  Gate remains CLOSED (system switched; Home not activated)." >&2
  exit 2
fi

had_pivot_before=0
[ -e "$pivot" ] && had_pivot_before=1

if ! herd restart guix-home-"$HOME_USER" >/dev/null 2>&1; then
  echo "reconfigure: system generation switched, but Home hot-activation" >&2
  echo "  could not be started (herd restart rejected). Gate remains" >&2
  echo "  CLOSED; next boot recovers via the official service." >&2
  exit 2
fi

# 3. 验证：activate 是异步的（forkexec），轮询链接直到出现且指向 store；
#    pivot 残留（~/.guix-home.new）是上次失败激活的标志。
i=0
ok=0
while [ "$i" -lt 30 ]; do
  if [ -L "/home/$HOME_USER/.guix-home" ] && \
     readlink "/home/$HOME_USER/.guix-home" 2>/dev/null | grep -q '^/gnu/store/'; then
    ok=1
    break
  fi
  i=$((i + 1))
  sleep 1
done

new_link=""
if [ -L "/home/$HOME_USER/.guix-home" ]; then
  new_link="$(readlink "/home/$HOME_USER/.guix-home")"
fi

if [ "$ok" -eq 0 ] || [ -e "$pivot" ]; then
  # 本次激活失败产生的 stale pivot：preflight 后无 pivot 而现在有 →
  # 确知是本次产生的，安全清理（仅 symlink 指向 store home 时清理），
  # 不覆盖原始 activation 错误。
  if [ "$had_pivot_before" -eq 0 ] && [ -e "$pivot" ]; then
    if ! guile -L "$ROOT/modules" -s "$ROOT/tools/home-pivot.scm" \
           --clean "$pivot" >/dev/null 2>&1; then
      echo "reconfigure: additionally, cleanup of the stale pivot from" >&2
      echo "  THIS failed activation failed; manual attention required:" >&2
      echo "  $pivot" >&2
    fi
  fi
  echo "reconfigure: system generation switched OK, but Home hot-activation" >&2
  echo "  FAILED (old Home: ${old_link:-none}; system is NOT rolled back)." >&2
  echo "  Gate remains CLOSED (new interactive sessions refused)." >&2
  echo "  Investigate: pivot residue /home/$HOME_USER/.guix-home.new, or" >&2
  echo "  ~/.guix-home occupied by a non-symlink. Fix, then re-run this" >&2
  echo "  script to recover without reboot." >&2
  exit 2
fi

# 4. readiness 复查：各 capability 服务无 failed
# （guixcfg-password-project 是已删除的旧 provision；当前 authoritative
#  account capability 是 account-state-ready——见 docs/architecture/
#  upstream-boundaries.md）
for svc in guixcfg-secrets-deploy account-state-ready \
           persistent-state-ready home-ready session-infra-ready \
           interactive-session-ready; do
  if herd status "$svc" 2>/dev/null | grep -q "Failed to start"; then
    echo "reconfigure: capability $svc is FAILED; gate remains CLOSED." >&2
    echo "  Fix the cause, then re-run this script to recover." >&2
    exit 2
  fi
done

# 5. 打开 gate
rm -f "$GATE"

if [ "$new_link" = "$old_link" ]; then
  echo "reconfigure: OK (Home closure unchanged; link idempotent: $new_link)"
else
  echo "reconfigure: OK (Home hot-switched $old_link -> $new_link)"
fi
