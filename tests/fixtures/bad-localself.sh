#!/usr/bin/env bash
# 违规样本：同一条 local 语句里引用前面刚声明的变量。
# bash 在执行 local 之前就把整行参数展开完了，${ver} 取到的是外层作用域，
# 多半是空串，而且不报任何错 —— 功能会静默失效。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local ver="${1:-1.0.0}" url="https://example.com/v${ver}/x.tar.gz"
  printf '%s\n' "$url"
}

main "$@"
