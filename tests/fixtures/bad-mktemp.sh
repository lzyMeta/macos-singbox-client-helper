#!/usr/bin/env bash
# 违规样本：mktemp 模板在 XXXXXX 之后还带后缀。
# BSD 版 mktemp 要求 XXXXXX 必须在模板末尾，不支持 sb-XXXXXX.json 这种写法。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local t
  t=$(mktemp /tmp/sb-XXXXXX.json)
  printf '%s\n' "$t"
}

main "$@"
