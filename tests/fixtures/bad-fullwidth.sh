#!/usr/bin/env bash
# 违规样本：变量后紧贴全角字符，bash 3.2 会解析错。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local name="${1:-world}"
  printf '%s\n' "$name中文"
}

main "$@"
