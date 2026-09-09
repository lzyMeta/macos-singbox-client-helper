#!/usr/bin/env bash
# 违规样本：bash 4 专有语法。macOS 自带的是 bash 3.2.57，没有关联数组、
# 没有 ${x^^} 大小写转换、没有 mapfile。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  declare -A seen
  seen[a]=1
  local name="${1:-x}"
  printf '%s\n' "${name^^}"
}

main "$@"
