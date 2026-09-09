#!/usr/bin/env bash
# 合规样本：换 $LAUNCHER 一律走 mv（rename）。
# mv 换的是目录项，旧 inode 被 unlink 但仍被当前进程打开着，
# 正在跑的脚本读到的还是那一份完整的旧内容。
#
# 同时钉住第 13 项**不该**报的两种写法 —— 少了这个样本，那一项就可能恒红：
#   1. cp 的目标是 $LAUNCHER.prev（备份，不是正在跑的那一份）
#   2. cp 的**来源**是 $LAUNCHER（读它不会动它）
#   3. && 右边的 cp 目标同样是 .prev
set -uo pipefail

LAUNCHER=/usr/local/bin/singbox

install_launcher() {
  local tmp="$1"
  [ -f "$LAUNCHER" ] && sudo cp "$LAUNCHER" "$LAUNCHER.prev"
  cp "$LAUNCHER" "$LAUNCHER.prev"
  chmod 755 "$tmp"
  sudo mv -f "$tmp" "$LAUNCHER" || exit 1
}
