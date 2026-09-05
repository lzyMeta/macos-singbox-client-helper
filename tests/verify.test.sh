#!/usr/bin/env bash
#
# tests/verify.test.sh —— cmd_verify 两档退出码的断言。
#
# 这份测试盯的是同一件事：**「测不了」不能再和「测过了」长得一样**。
# 所以每条都验退出码，不只看输出——五步里凡是打了 ✗ 的分支，退出码必须跟着动：
#
#   0  全过
#   1  链路档失败（节点/出口 IP —— 换回旧内核有用，该回滚）
#   2  仅策略档失败（DNS/QUIC/国内直连 —— 路由策略问题，回滚换不回来，不该回滚）
#
# 全程离线、不要 sudo、不碰真实系统：tests/fixtures/bin 前置到 PATH，
# --prefix 指到临时目录。cmd_verify 不会真去连端口，所以这里不需要起监听进程。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB=./singbox.sh
FIXBIN="$PWD/tests/fixtures/bin"

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -30 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

# 现网监听端口。这里没有任何东西真的 bind，假 curl 只拿它跟 socks5h:// 的端口比对，
# 所以撞不上这台机器上可能正跑着的真 sing-box。
LIVE_PORT=21808

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state"; mkdir -p "$SB_FAKE_STATE"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"

  export SB_FAKE_LIVE_PORT="$LIVE_PORT"
  echo 1 > "$SB_FAKE_STATE/running"        # 服务在跑
  echo 0 > "$SB_FAKE_STATE/verify_calls"
  echo 0 > "$SB_FAKE_STATE/ping_calls"
  echo 0 > "$SB_FAKE_STATE/ipinfo_calls"

  cat > "$ROOT/prefix/etc/sing-box/config.json" <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
      "listen_port": ${LIVE_PORT} }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
JSON
  # require_installed 只要求 $BIN 可执行；verify 从不去跑它
  : > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"

  # ⚠️ 默认必须钉死 QUIC 结果。不钉的话第 4 步会真的往公网发 UDP 包：
  # 联网时判「未阻断」→ 每条用例都莫名其妙变成退出 2；离线时每次白等两个超时。
  export SB_FAKE_QUIC=blocked

  unset SB_FAKE_VERIFY_FAIL SB_FAKE_DIG_FAIL SB_FAKE_DIG_IP SB_FAKE_HOST_FAIL \
        SB_FAKE_HOST_IP SB_FAKE_DSCACHEUTIL_FAIL SB_FAKE_DSCACHEUTIL_IP \
        SB_FAKE_PY_RESOLVE_FAIL SB_FAKE_CN_IP SB_FAKE_CN_FAIL SB_FAKE_NO_GW \
        SB_FAKE_PING_FAIL SB_FAKE_IPINFO_FAIL SB_FAKE_IPINFO_JUNK SB_FAKE_PROBE_FAIL
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf /tmp/.singbox-sh.lock 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# sb —— 跑一次 singbox.sh verify，退出码进 $CODE
sb() { PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y verify >"$LOG" 2>&1; CODE=$?; }

inlog()   { grep -q "$1" "$LOG"; }
pings()   { cat "$SB_FAKE_STATE/ping_calls" 2>/dev/null || echo 0; }
ipinfos() { cat "$SB_FAKE_STATE/ipinfo_calls" 2>/dev/null || echo 0; }

echo "验证 cmd_verify 的两档退出码"

#-- 1. 全部桩正常 -------------------------------------------------------
setup
sb
if [ "$CODE" = 0 ]; then
  ok "全部正常：退出 0"
else
  ng "全部正常：期望 0，实际 $CODE"
fi

#-- 2. 第 1 步失败：链路档 ----------------------------------------------
setup
SB_FAKE_VERIFY_FAIL=all sb
if [ "$CODE" = 1 ]; then
  ok "SOCKS 不通：退出 1（链路档）"
else
  ng "SOCKS 不通：期望 1，实际 $CODE"
fi

#-- 3. dig 废了：降级到 host，不跳过 ------------------------------------
# 这是整份改动的核心断言。原实现 `command -v dig` 一 miss 就整步 dim 跳过，
# 退出码照样 0——「没检查」和「检查过了」在终端上一模一样。
setup
SB_FAKE_DIG_FAIL=1 sb
if [ "$CODE" = 0 ] && inlog "解析正常" && ! inlog "未装 dig"; then
  ok "dig 废了：降级到 host 后照样完成检查，退出 0"
else
  ng "dig 废了：期望退出 0 且日志里有「解析正常」、没有「未装 dig」（实际 ${CODE}）"
fi

#-- 4. 四级解析全废：硬失败，且与污染分开报 ------------------------------
setup
SB_FAKE_DIG_FAIL=1 SB_FAKE_HOST_FAIL=1 SB_FAKE_DSCACHEUTIL_FAIL=1 \
  SB_FAKE_PY_RESOLVE_FAIL=1 sb
if [ "$CODE" = 2 ] && inlog "可用解析手段" && ! inlog "污染"; then
  ok "四级全废：退出 2，报「无可用解析手段」，文案与污染分开"
else
  ng "四级全废：期望 2 且报无解析手段、不提污染（实际 ${CODE}）"
fi

#-- 5. 解析到污染名单里的地址 -------------------------------------------
setup
SB_FAKE_DIG_IP=157.240.1.1 sb
if [ "$CODE" = 2 ] && inlog "污染"; then
  ok "解析到 157.240.1.1：退出 2，报疑似污染"
else
  ng "解析到 157.240.1.1：期望 2 且报污染（实际 ${CODE}）"
fi

#-- 6. QUIC 没被挡住：硬失败（原为 warn） --------------------------------
setup
SB_FAKE_QUIC=open sb
if [ "$CODE" = 2 ] && inlog "QUIC" && inlog '✗'; then
  ok "QUIC 未阻断：退出 2 并打 ✗（不再是 warn，也不再跳过）"
else
  ng "QUIC 未阻断：期望 2 且打 ✗（实际 ${CODE}）"
fi

#-- 7. QUIC 被挡住：正控 ------------------------------------------------
setup
SB_FAKE_QUIC=blocked sb
if [ "$CODE" = 0 ] && inlog "QUIC 已阻断"; then
  ok "QUIC 已阻断：第 4 步 ok，退出 0"
else
  ng "QUIC 已阻断：期望 0 且日志有「QUIC 已阻断」（实际 ${CODE}）"
fi

#-- 8. 国内直连出口 == SOCKS 出口 ---------------------------------------
# 假 curl 的 SOCKS 出口固定是 1.2.3.4，把国内出口也报成它 —— 国内流量全被代理接走。
setup
SB_FAKE_CN_IP=1.2.3.4 sb
if [ "$CODE" = 2 ] && inlog "国内直连"; then
  ok "国内出口等于 SOCKS 出口：退出 2，报国内直连失效"
else
  ng "国内出口等于 SOCKS 出口：期望 2（实际 ${CODE}）"
fi

#-- 9. cip.cc 挂了但备胎可用 --------------------------------------------
setup
SB_FAKE_CN_FAIL=cip sb
if [ "$CODE" = 0 ]; then
  ok "cip.cc 挂了：备胎顶上，退出 0"
else
  ng "cip.cc 挂了：期望 0（实际 ${CODE}）"
fi

#-- 10. 三家全挂：这一步没有结论 = 硬失败 --------------------------------
setup
SB_FAKE_CN_FAIL=all sb
if [ "$CODE" = 2 ]; then
  ok "三家全挂：退出 2"
else
  ng "三家全挂：期望 2（实际 ${CODE}）"
fi

#-- 11. 拿不到默认网关：不再静默跳过 -------------------------------------
setup
SB_FAKE_NO_GW=1 sb
if [ "$CODE" = 2 ] && inlog "网关"; then
  ok "拿不到默认网关：退出 2（不再静默跳过）"
else
  ng "拿不到默认网关：期望 2 且日志点名网关（实际 ${CODE}）"
fi

#-- 12. 网关不通：连试 3 次才判失败 --------------------------------------
setup
SB_FAKE_PING_FAIL=1 sb
n=$(pings)
if [ "$CODE" = 2 ] && [ "$n" = 3 ]; then
  ok "网关不通：退出 2，且确实重试了 3 次"
else
  ng "网关不通：期望退出 2 且 ping 调用 3 次（实际 $CODE / ${n} 次）"
fi

#-- 13. ipinfo.io 回了非空但不是 JSON 的页面：仍要试满 3 次 ----------------
# 限流页 / 502 / Cloudflare 拦截页都是「非空但没法解析」。拿响应体非空当跳出条件的话
# 只会请求 1 次，然后打一句「连取 3 次都没结果」的假话——一次抖动就把 verify 判成 2。
setup
SB_FAKE_IPINFO_JUNK=1 sb
n=$(ipinfos)
if [ "$CODE" = 2 ] && [ "$n" = 3 ]; then
  ok "ipinfo.io 回非 JSON：退出 2，且确实试满了 3 次"
else
  ng "ipinfo.io 回非 JSON：期望退出 2 且请求 3 次（实际 ${CODE} / ${n} 次）"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
