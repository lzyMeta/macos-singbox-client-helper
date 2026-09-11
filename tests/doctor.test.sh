#!/usr/bin/env bash
#
# tests/doctor.test.sh —— doctor / status 对 TUN 路由的判读。
#
# 起因（2026-09-10 真机）：sing-box 1.14.0 + sing-tun v0.9 在 darwin 上把 0/1 这一半拆成
# 1/8 2/7 4/6 8/5 16/4 32/3 64/2 七段装（避开 0.0.0.0/8），上半仍是整条 128.0/1。
# doctor 的判读只认 `default|^0/1`，于是恒报「路由未指向 utun：TUN 未接管」；
# 而 status / _sb_health 认 128.0/1，只看上半——「只有上半在」这种真故障又会被判成健康。
# 三处判据要统一：上半 128.0/1 且下半（0/1 或七段齐全）都指向 utun 才算接管。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"
FIX="$PWD/tests/fixtures"

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ -n "$LOG" ] && [ -s "$LOG" ] && grep -E '路由|utun|一半|接管' "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box" "$ROOT/logs"
  sed "s/__VERSION__/1.14.0/" "$FAKE" > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"
  cp "$FIX/good-http-client.json" "$ROOT/prefix/etc/sing-box/config.json"
  export XDG_CONFIG_HOME="$ROOT/xdg"; mkdir -p "$XDG_CONFIG_HOME"
  export SB_FAKE_STATE="$ROOT/state"; mkdir -p "$SB_FAKE_STATE"
  echo 1 > "$SB_FAKE_STATE/running"
  export SB_FAKE_SCHEMA="$FIX/schema-min.json"
  export SB_LOGDIR="$ROOT/logs"; : > "$ROOT/logs/sing-box.log"; : > "$ROOT/logs/sing-box.err"
  unset SB_FAKE_NO_TUN SB_FAKE_TUN_HOST_ONLY SB_FAKE_TUN_UPPER_ONLY SB_FAKE_TUN_ZERO_ONE
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf "${SB_LOCKDIR:-/tmp/.singbox-sh.lock}" 2>/dev/null
  ROOT=""
}
trap teardown EXIT

sb() { PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" >"$LOG" 2>&1; CODE=$?; }
inlog() { grep -q "$1" "$LOG"; }

echo "验证 doctor / status 的 TUN 路由判读"

#-- 1. 七段拆分（真机形状）：不是误报 -------------------------------------------
setup
sb doctor
if inlog '路由未指向 utun'; then
  ng "doctor：七段拆分被误报成「路由未指向 utun」"
else
  ok "doctor：七段拆分不报「路由未指向 utun」"
fi
if inlog '未发现已知问题模式' && [ "$CODE" = 0 ]; then
  ok "doctor：七段拆分下判读干净，退出 0"
else
  ng "doctor：七段拆分下仍有判读或退出 ${CODE}"
fi
sb status
if inlog '路由已指向 utun'; then ok "status：七段拆分判为已接管"; else ng "status：七段拆分没判为已接管"; fi

#-- 2. 老装法：整条 0/1 + 128.0/1，也算接管 ----------------------------------------
setup
SB_FAKE_TUN_ZERO_ONE=1 sb doctor
if ! inlog '路由未指向 utun' && ! inlog '一半'; then
  ok "doctor：整条 0/1 + 128.0/1 判为已接管"
else
  ng "doctor：整条 0/1 + 128.0/1 被误报"
fi

#-- 3. 只有主机路由：必须报未接管（守住上面两条不是恒绿）-----------------------------
setup
SB_FAKE_TUN_HOST_ONLY=1 sb doctor
if inlog '路由未指向 utun' && [ "$CODE" != 0 ]; then
  ok "doctor：只有 UH 主机路由 → 报「路由未指向 utun」，退非 0"
else
  ng "doctor：只有 UH 主机路由却没报未接管（退出 ${CODE}）"
fi

#-- 4. 只有上半：一半地址裸奔，doctor 与 status 都要点名「一半」-----------------------
setup
SB_FAKE_TUN_UPPER_ONLY=1 sb doctor
if inlog '一半' && [ "$CODE" != 0 ]; then
  ok "doctor：只有 128.0/1 → 点名「一半」，退非 0"
else
  ng "doctor：只有 128.0/1 没点名「一半」（退出 ${CODE}）"
fi
SB_FAKE_TUN_UPPER_ONLY=1 sb status
if inlog '一半'; then ok "status：只有 128.0/1 → 点名「一半」"; else ng "status：只有 128.0/1 没点名「一半」"; fi

#-- 5. 没有 utun：报未接管 ------------------------------------------------------------
setup
SB_FAKE_NO_TUN=1 sb doctor
if inlog '路由未指向 utun' && [ "$CODE" != 0 ]; then
  ok "doctor：没有 utun → 报未接管，退非 0"
else
  ng "doctor：没有 utun 却没报未接管（退出 ${CODE}）"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
