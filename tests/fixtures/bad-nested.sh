#!/usr/bin/env bash
# 违规样本：函数体内嵌套定义函数。
# 内层函数会捕获外层的 local；trap 又是在函数返回之后才触发，
# 那时作用域已经销毁。缩进故意用 6 个空格 —— 检查项的内层正则若写死
# 「恰好 2 个空格」就抓不到它，那一项会恒绿、永远不报。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local tag="${1:-x}"
  case "$tag" in
    run)
      local m
      _inner() {
        printf '%s\n' "$1"
      }
      _inner "$tag"
      ;;
  esac
}

main "$@"
