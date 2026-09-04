#!/usr/bin/env bash
# 违规样本：数组在 set -u 下裸展开，空数组会直接报 unbound variable。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local args=()
  printf '%s\n' "${args[@]}"
}

main "$@"
