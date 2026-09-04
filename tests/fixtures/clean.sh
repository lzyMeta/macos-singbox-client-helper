#!/usr/bin/env bash
# 干净样本：不触犯 singbox-selfcheck.sh 的任何一条规则。
# 故意包含两种「看着像违规、其实合规」的写法，用来验证检查项不会误报：
#   1. ${name}，  —— 带花括号，全角字符前有 } 收尾
#   2. "${args[@]+"${args[@]}"}"  —— set -u 下的安全展开形式
set -uo pipefail

msg() {
  printf '%s\n' "$1"
}

main() {
  local name="${1:-world}"
  msg "你好，${name}。欢迎"
  local args=()
  args+=(-n)
  printf '%s\n' "${args[@]+"${args[@]}"}"
}

main "$@"
