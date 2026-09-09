#!/usr/bin/env bash
# 违规样本：用了已废弃的 launchctl load / unload。
# 现代 launchd 要用 bootstrap / bootout，旧接口在部分系统上静默不生效。
# 只犯这一条，其余规则全部合规。
set -uo pipefail

main() {
  local plist="${1:-/tmp/x.plist}"
  sudo launchctl load "$plist"
  sudo launchctl unload "$plist"
}

main "$@"
