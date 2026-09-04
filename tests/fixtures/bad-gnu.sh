#!/usr/bin/env bash
# 违规样本：使用 GNU 专有的 grep -P（PCRE），macOS 自带的 BSD grep 不支持。
# 只犯这一条，其余规则全部合规。
# 用 -nP 而不是 -oP，是因为这正是 singbox-selfcheck.sh 自己曾经踩过、
# 而当时那条 GNU 规则没能拦住的写法。
set -uo pipefail

main() {
  local f="${1:-/dev/null}"
  grep -nP '\d+' "$f"
}

main "$@"
