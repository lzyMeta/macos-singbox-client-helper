#!/usr/bin/env bash
# 干净样本：不触犯 singbox-selfcheck.sh 的任何一条规则。
# 故意包含一批「看着像违规、其实合规」的写法，用来验证检查项不会误报：
#   1. ${name}，                  —— 带花括号，全角字符前有 } 收尾
#   2. "${args[@]+"${args[@]}"}"  —— set -u 下的安全展开形式
#   3. shift 2 之前有 || die      —— 参数缺失时干净退出，不会死循环
#   4. local s; s=$(...); local p —— 分号隔开的独立语句，不是同一条 local
#   5. grep -c 不叠加 || echo     —— 不会产生 "0\n0"
#   6. mktemp 模板 XXXXXX 收尾    —— BSD mktemp 认这种
#   7. launchctl bootout          —— 不是废弃的 load/unload
#   8. 函数只在顶层定义           —— 没有嵌套定义
set -uo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

msg() {
  printf '%s\n' "$1"
}

parse() {
  local cfg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) cfg="${2:-}"; [ -n "$cfg" ] || die "--config 需要参数"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$cfg"
}

count_errors() {
  local f="${1:-/dev/null}"
  local n; n=$(grep -ci 'error' "$f" 2>/dev/null); n="${n:-0}"
  [ "$n" -gt 0 ] && msg "有错误"
  return 0
}

split_addr() {
  local s; s=$(printf '%s' "127.0.0.1:10808"); local p="${s##*:}"
  msg "$p"
}

make_tmp() {
  local t; t=$(mktemp /tmp/sb-XXXXXX)
  printf '%s\n' "$t"
}

reload() {
  local plist="${1:-/tmp/x.plist}"
  sudo launchctl bootout system "$plist" 2>/dev/null || true
}

main() {
  local name="${1:-world}"
  msg "你好，${name}。欢迎"
  local args=()
  args+=(-n)
  printf '%s\n' "${args[@]+"${args[@]}"}"
}

main "$@"
