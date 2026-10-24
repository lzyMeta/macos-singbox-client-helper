#!/usr/bin/env bash
#
# tests/dns.test.sh —— start / stop / restart 对系统 DNS 的处理，按网络服务逐个看。
#
# 盯的是一个真机形状（2026-10-23）：dns-backup 是 install 时记的，只有 Thunderbolt Bridge
# 与 Wi-Fi；iPhone USB 是之后才插上的。stop 按备份还原只动了备份里的两个，iPhone USB 还停在
# 1.1.1.1；start 判「是不是代理模式」用的是「任一服务 = 1.1.1.1」，看到 iPhone USB 就不问了，
# Wi-Fi 于是一直是 DHCP 下发的内网 DNS——verify 照样全绿，只有 syscheck 报出来。
#
# 全程离线、不要 sudo、不碰真实系统：tests/fixtures/bin 前置到 PATH，--prefix 指到临时目录。
# 假 networksetup 的写操作只记进 dns_events，断言都看它。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"   # 换成旧版脚本即可验证某条断言不是恒绿的
FIXBIN="$PWD/tests/fixtures/bin"

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -25 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state";  mkdir -p "$SB_FAKE_STATE"
  export SB_LOGDIR="$ROOT/log";        mkdir -p "$SB_LOGDIR"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME/singbox"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"
  # require_installed 只要求 $BIN 可执行、$CFG 存在；这几条路径都不去跑内核
  : > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"
  echo '{}' > "$ROOT/prefix/etc/sing-box/config.json"

  echo 0 > "$SB_FAKE_STATE/running"
  echo 1 > "$SB_FAKE_STATE/loaded"
  : > "$SB_FAKE_STATE/btm_events"
  : > "$SB_FAKE_STATE/dns_events"

  export SB_FAKE_SERVICES=$'Wi-Fi\niPhone USB'
  # 假 launchctl 拿现网二进制的版本跟 SB_FAKE_START_FAIL 比；这里的 $BIN 是空文件、版本取出来
  # 是空串，不设的话「空 = 空」就判成起不来。给一个不可能撞上的值。
  export SB_FAKE_START_FAIL=never
  unset SB_FAKE_DNS SB_FAKE_DNS_MAP SB_FAKE_DAEMON_LOADED SB_FAKE_BTM_PIN \
        SB_FAKE_LIVE_BIN SB_FAKE_LIVE_PORT SB_FAKE_CACHE_DB
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf "${SB_LOCKDIR:-/tmp/.singbox-sh.lock}" 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# sb <子命令…> —— 跑一次 singbox.sh，退出码进 $CODE
sb() { PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" >"$LOG" 2>&1; CODE=$?; }

dns_events() { cat "$SB_FAKE_STATE/dns_events" 2>/dev/null; }
# set_to <服务> <地址> —— dns_events 里有没有把这个服务设成这个地址
set_to() { grep -qxF "setdns:-setdnsservers $1 $2" "$SB_FAKE_STATE/dns_events" 2>/dev/null; }
backup() { printf '%s\n' "$@" | tr '|' '\t' > "$XDG_CONFIG_HOME/singbox/dns-backup"; }

echo "验证 start / stop / restart 按网络服务处理系统 DNS"

#-- 1. start：一个服务已是代理 DNS、另一个是内网 —— 内网那个要被设回去 ----------
setup
export SB_FAKE_DNS_MAP=$'Wi-Fi=none\niPhone USB=1.1.1.1'
sb start
if [ "$CODE" = 0 ] && set_to Wi-Fi 1.1.1.1; then
  ok "start：Wi-Fi 未设、iPhone USB 已是 1.1.1.1 —— Wi-Fi 被设为 1.1.1.1"
else
  ng "start：期望退 0 且 Wi-Fi 被设为 1.1.1.1（退出 ${CODE}）" "$(dns_events)"
fi

#-- 2. start：所有服务都已是代理 DNS —— 一下都不该动 ------------------------------
setup
export SB_FAKE_DNS=1.1.1.1
sb start
if [ "$CODE" = 0 ] && [ ! -s "$SB_FAKE_STATE/dns_events" ]; then
  ok "start：全部已是 1.1.1.1 —— 不写 DNS"
else
  ng "start：期望退 0 且没有任何 setdns（退出 ${CODE}）" "$(dns_events)"
fi

#-- 3. stop：备份里没有的服务（install 之后才插上的）也要交回 DHCP ------------------
setup
echo 1 > "$SB_FAKE_STATE/running"
export SB_FAKE_DNS=1.1.1.1
backup 'Wi-Fi|empty'
sb stop --restore-dns
if [ "$CODE" = 0 ] && set_to Wi-Fi empty && set_to 'iPhone USB' empty; then
  ok "stop --restore-dns：备份只有 Wi-Fi —— iPhone USB 也交回 DHCP"
else
  ng "stop --restore-dns：期望 Wi-Fi 与 iPhone USB 都被设为 empty（退出 ${CODE}）" "$(dns_events)"
fi

#-- 4. stop：备份里的原值照旧按备份还原，不被「交回 DHCP」覆盖 ---------------------
setup
echo 1 > "$SB_FAKE_STATE/running"
export SB_FAKE_DNS=1.1.1.1
backup 'Wi-Fi|10.0.0.53'
sb stop --restore-dns
if [ "$CODE" = 0 ] && set_to Wi-Fi 10.0.0.53 && ! set_to Wi-Fi empty && set_to 'iPhone USB' empty; then
  ok "stop --restore-dns：Wi-Fi 回到备份的 10.0.0.53，iPhone USB 交回 DHCP"
else
  ng "stop --restore-dns：期望 Wi-Fi→10.0.0.53（且不再被设 empty）、iPhone USB→empty（退出 ${CODE}）" "$(dns_events)"
fi

#-- 5. restart（kickstart 那支）：同样要把内网那个服务设回去 -------------------------
setup
echo 1 > "$SB_FAKE_STATE/running"
export SB_FAKE_DNS_MAP=$'Wi-Fi=none\niPhone USB=1.1.1.1'
sb restart
if [ "$CODE" = 0 ] && grep -q '^kickstart' "$SB_FAKE_STATE/btm_events" && set_to Wi-Fi 1.1.1.1; then
  ok "restart（kickstart）：Wi-Fi 未设 —— 重启后被设为 1.1.1.1"
else
  ng "restart（kickstart）：期望走 kickstart 且 Wi-Fi 被设为 1.1.1.1（退出 ${CODE}）" \
     "$(cat "$SB_FAKE_STATE/btm_events"; dns_events)"
fi

#-- 6. restart（服务未加载 → 直接 start）：同上 ------------------------------------
setup
echo 0 > "$SB_FAKE_STATE/loaded"
export SB_FAKE_DNS_MAP=$'Wi-Fi=none\niPhone USB=1.1.1.1'
sb restart
if [ "$CODE" = 0 ] && grep -q '^bootstrap' "$SB_FAKE_STATE/btm_events" && set_to Wi-Fi 1.1.1.1; then
  ok "restart（未加载）：走 bootstrap，Wi-Fi 被设为 1.1.1.1"
else
  ng "restart（未加载）：期望走 bootstrap 且 Wi-Fi 被设为 1.1.1.1（退出 ${CODE}）" \
     "$(cat "$SB_FAKE_STATE/btm_events"; dns_events)"
fi

#-- 7. restart（kickstart）：全部已是代理 DNS —— 不写 DNS ----------------------------
setup
echo 1 > "$SB_FAKE_STATE/running"
export SB_FAKE_DNS=1.1.1.1
sb restart
if [ "$CODE" = 0 ] && [ ! -s "$SB_FAKE_STATE/dns_events" ]; then
  ok "restart（kickstart）：全部已是 1.1.1.1 —— 不写 DNS"
else
  ng "restart（kickstart）：期望退 0 且没有任何 setdns（退出 ${CODE}）" "$(dns_events)"
fi

# dns status 的结论行。逐服务表格那几行以 6 个空格起头、带地址，漏掉的服务清单是 8 个空格、
# 只有服务名——断言只认后者，表格里本来就有 Wi-Fi，拿它当证据是恒绿。
listed() { grep -qxE "        $1" "$LOG"; }

#-- 8. dns status：服务在跑、一个服务是 1.1.1.1、Wi-Fi 未设 —— 不许说「正确状态」 --------
setup
echo 1 > "$SB_FAKE_STATE/running"
export SB_FAKE_DNS_MAP=$'Wi-Fi=none\niPhone USB=1.1.1.1'
sb dns status
# 「仍有服务指向 1.1.1.1 —— 用 dns dhcp」是停服还原之后才该说的话，服务在跑时说它就是叫人去拆代理
if [ "$CODE" = 0 ] && ! grep -q '正确状态' "$LOG" && grep -q 'dns proxy' "$LOG" && ! grep -q 'dns dhcp' "$LOG" \
   && listed Wi-Fi && ! listed 'iPhone USB'; then
  ok "dns status（在跑、混合）：点名 Wi-Fi、建议 dns proxy，不说「正确状态」也不建议 dns dhcp"
else
  ng "dns status（在跑、混合）：期望退 0、点名 Wi-Fi 并建议 dns proxy、不出现「正确状态」与 dns dhcp（退出 ${CODE}）"
fi

#-- 9. dns status：服务在跑、全部已是代理 DNS —— 正确状态，不建议改 ----------------------
setup
echo 1 > "$SB_FAKE_STATE/running"
export SB_FAKE_DNS=1.1.1.1
sb dns status
if [ "$CODE" = 0 ] && grep -q '正确状态' "$LOG" && ! grep -q 'dns proxy' "$LOG" && ! grep -q 'dns dhcp' "$LOG"; then
  ok "dns status（在跑、全部 1.1.1.1）：报正确状态，不建议改"
else
  ng "dns status（在跑、全部 1.1.1.1）：期望退 0、「正确状态」、不建议 dns proxy / dns dhcp（退出 ${CODE}）"
fi

#-- 10. dns status：服务没跑、还有服务指向 1.1.1.1 —— 照旧建议 dns dhcp ------------------
# 三条都没写 dns-backup：status 以前在没有备份时退 1（末行 `[ -f … ] && {…}` 的返回值漏出去）
setup
export SB_FAKE_DNS_MAP=$'Wi-Fi=none\niPhone USB=1.1.1.1'
sb dns status
if [ "$CODE" = 0 ] && grep -q 'dns dhcp' "$LOG" && ! grep -q '正确状态' "$LOG"; then
  ok "dns status（没跑、iPhone USB 仍是 1.1.1.1）：建议 dns dhcp"
else
  ng "dns status（没跑、混合）：期望建议 dns dhcp、不出现「正确状态」（退出 ${CODE}）"
fi

echo
echo "通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
