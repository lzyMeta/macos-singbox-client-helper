#!/usr/bin/env bash
# 违规样本：用 cp / install 直接覆盖 $LAUNCHER。
#
# bash 是边执行边按偏移量读脚本文件的。cp / install 覆盖的是**同一个 inode**，
# 正在跑的这个进程下一次读取会读到新文件的字节流、落在错误的偏移上 ——
# 症状是执行到一半冒出莫名其妙的语法错误，且只在「脚本更新自己」这条路径上出现。
set -uo pipefail

LAUNCHER=/usr/local/bin/singbox

update_self() {
  local tmp="$1"
  sudo cp "$tmp" "$LAUNCHER"
  sudo install -m 755 "$tmp" "$LAUNCHER" || exit 1
}
