#!/bin/sh
# reconfigure orchestration（docs/deployment.md 的 configctl system switch
# 在 VM 阶段的最小实现；configctl 全套——git 干净检查/只读快照/部署记录——
# 仍是规划中的未来工作）。
#
# 职责：system reconfigure + 成功后热激活绑定的 Guix Home。
#
# 为什么需要显式热激活验证（错误语义见 docs/system-home-boundaries.md J5）：
#   `guix system reconfigure` 的服务升级对 one-shot 服务是 fire-and-forget：
#   shepherd 把 activate 进程 fork 出去即视为成功——Home activate 失败
#   （如 ~/.guix-home 位置被非空目录阻塞、或上次失败残留的
#   ~/.guix-home.new pivot）不会反馈到 reconfigure 退出码。这里在
#   reconfigure 成功后显式 restart + 验证链接状态，失败时明确报告。
#
# 错误语义：
#   1. system reconfigure 失败   → exit 1，Home 完全不动；
#   2. system 成功 + Home 失败   → exit 2，明确报告 system 已切换、
#      Home 热激活失败；不回滚 system；下次启动官方
#      guix-home-service-type 会用当前 system generation 的 Home 恢复。
#
# 用法（root）：tools/reconfigure.sh [host]   # host 默认 vm
# 环境变量：HOME_USER 指定 Home 绑定用户（默认 user）。

set -eu

HOST="${1:-vm}"
HOME_USER="${HOME_USER:-user}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

old_link=""
if [ -L "/home/$HOME_USER/.guix-home" ]; then
  old_link="$(readlink "/home/$HOME_USER/.guix-home")"
fi

# 1. system reconfigure（失败则 Home 完全不动）
if ! guix time-machine -C channels.lock.scm -- system reconfigure \
       "modules/guixcfg/hosts/$HOST.scm" -L modules; then
  echo "reconfigure: system reconfigure FAILED; Home left untouched." >&2
  exit 1
fi

# 2. 热激活 Home（幂等：home closure 未变时 activate 重建同一组链接）
if ! herd restart guix-home-"$HOME_USER" >/dev/null 2>&1; then
  echo "reconfigure: system generation switched, but Home hot-activation" >&2
  echo "  could not be started (herd restart rejected). The official service" >&2
  echo "  will restore Home from the current generation at next boot." >&2
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

if [ "$ok" -eq 0 ] || [ -e "/home/$HOME_USER/.guix-home.new" ]; then
  echo "reconfigure: system generation switched OK, but Home hot-activation" >&2
  echo "  FAILED (old Home: ${old_link:-none}; system is NOT rolled back)." >&2
  echo "  Investigate: pivot residue /home/$HOME_USER/.guix-home.new, or" >&2
  echo "  ~/.guix-home occupied by a non-symlink. Next boot will recover via" >&2
  echo "  the official guix-home-service-type from the current generation." >&2
  exit 2
fi

if [ "$new_link" = "$old_link" ]; then
  echo "reconfigure: OK (Home closure unchanged; link idempotent: $new_link)"
else
  echo "reconfigure: OK (Home hot-switched $old_link -> $new_link)"
fi
