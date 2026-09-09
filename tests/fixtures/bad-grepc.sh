#!/usr/bin/env bash
# 违规样本：命令替换里给 grep -c 叠加 || echo 兜底。
# grep -c 无匹配时**已经打印了 0** 并返回 1，那个 || 会再追加一个，
# 变量变成 "0\n0"，后面的 [ -gt ] 会把 integer expression expected
# 打到用户终端 —— 而且只在一切正常（无匹配）时发生。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local f="${1:-/dev/null}"
  local n
  n=$(grep -ci 'error' "$f" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ] && printf '%s\n' "有错误"
  return 0
}

main "$@"
