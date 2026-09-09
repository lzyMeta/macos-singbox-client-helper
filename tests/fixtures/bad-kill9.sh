#!/usr/bin/env bash
# 违规样本：kill -9 强杀 sing-box。
# 强杀不给内核收尾的机会，会在路由表里留下残留，症状是网络时好时坏，
# 且不指向真正的原因。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local pid="${1:-0}"
  kill -9 "$pid"
}

main "$@"
