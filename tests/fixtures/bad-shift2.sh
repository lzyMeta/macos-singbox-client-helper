#!/usr/bin/env bash
# 违规样本：shift 2 之前没有校验 $2 存在。
# bash 3.2 的 shift n 在 n > $# 时返回 1 且**不消耗任何参数**，
# 于是 while [ $# -gt 0 ] 的解析循环永不终止，脚本挂死、CPU 跑满。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local cfg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) cfg="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$cfg"
}

main "$@"
