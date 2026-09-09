#!/usr/bin/env bash
# 违规样本：bash 语法错误（if 没有 fi）。用来钉住 `bash -n` 那一项。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  if [ "${1:-}" = x ]; then
    printf 'x\n'
}

main "$@"
