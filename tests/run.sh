#!/usr/bin/env bash
#
# tests/run.sh —— 跑 tests/ 下所有 *.test.sh。
# 有一个红就整体红，但不早退：一次跑完看到全部失败，比修一个跑一次快。
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

rc=0
for t in tests/*.test.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s ===\n' "$t"
  # 每个测试文件一把自己的锁：默认的 /tmp/.singbox-sh.lock 会跟 live 的 singbox
  # 命令、以及前一个测试残留的锁撞上，acquire_lock 等 6 秒就 die
  lockroot=$(mktemp -d)
  if ! SB_LOCKDIR="$lockroot/lock" "$t"; then rc=1; fi
  rm -rf "$lockroot"
done

echo
[ "$rc" = 0 ] && echo "tests/ 全部通过" || echo "tests/ 有失败"
exit "$rc"
