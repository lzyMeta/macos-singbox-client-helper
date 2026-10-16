#!/usr/bin/env bash
#
# tests/rules.test.sh —— cmd_rules 的两种动作：不带参数只验 URL，`rules update` 强制重下。
#
# 全程离线、不要 sudo、不碰真实系统：tests/fixtures/bin 前置到 PATH，--prefix 指到临时目录。
# ⚠️ 配置里的 cache_file.path 必须落在 $ROOT 下。假 sudo 对 mv 是真执行——照抄
# update.test.sh 那份配置（path 写的是 /usr/local/etc/sing-box/cache.db），
# 这里就会去搬这台机器上 live 的缓存。
#
# 每条用例盯的是同一件事：**预检或前置条件没过，服务一下都不该被停**（看 btm_events
# 里有没有 bootout），缓存一个字节都不该被动；真换了缓存，起不来就必须换回去。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"   # 换成旧版脚本即可验证某条断言不是恒绿的
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -25 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

free_port() {
  python3 - "$1" <<'PORTPY'
import socket, sys
for p in range(int(sys.argv[1]), int(sys.argv[1]) + 300):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        continue
    finally:
        s.close()
    print(p); break
PORTPY
}

port_busy() {
  python3 -c 'import socket,sys
sys.exit(0 if socket.socket().connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$1"
}

sig() { [ -f "$1" ] && shasum "$1" | awk '{print $1}'; }

ETC() { printf '%s' "$ROOT/prefix/etc/sing-box"; }

# 写现网配置。CACHE_MODE：rel（相对路径 cache.db）| nopath（不写 path）| abs:<路径> | off
#             CLASH：1 开 clash_api（带 secret）| 0 不开
write_cfg() {
  CACHE_MODE="${1:-rel}" CLASH="${2:-1}" python3 - "$(ETC)/config.json" <<'PY'
import json, os, sys
mode = os.environ["CACHE_MODE"]
cfg = {
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "interface_name": "utun4",
     "address": ["172.19.0.1/30"], "auto_route": True},
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
     "listen_port": int(os.environ["SB_FAKE_LIVE_PORT"])},
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"rule_set": [
    {"type": "remote", "tag": "geosite-cn", "format": "binary",
     "url": "https://example.invalid/geosite-cn.srs"},
    {"type": "remote", "tag": "geoip-cn", "format": "binary",
     "url": "https://example.invalid/geoip-cn.srs"},
    {"type": "local", "tag": "mine", "format": "source", "path": "mine.json"},
  ]},
  "experimental": {},
}
cf = {"enabled": True}
if mode == "rel":
    cf["path"] = "cache.db"
elif mode.startswith("abs:"):
    cf["path"] = mode[4:]
elif mode == "off":
    cf = {"enabled": False, "path": "cache.db"}
cfg["experimental"]["cache_file"] = cf
if os.environ["CLASH"] == "1":
    cfg["experimental"]["clash_api"] = {
        "external_controller": "0.0.0.0:" + os.environ["SB_FAKE_LIVE_CLASH_PORT"],
        "secret": "s3cret"}
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
}

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state";  mkdir -p "$SB_FAKE_STATE"
  export SB_LOGDIR="$ROOT/log";        mkdir -p "$SB_LOGDIR"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME"
  mkdir -p "$ROOT/prefix/bin" "$(ETC)"

  export SB_FAKE_LIVE_BIN="$ROOT/prefix/bin/sing-box"
  sed "s/__VERSION__/1.14.3/" "$FAKE" > "$SB_FAKE_LIVE_BIN"; chmod 755 "$SB_FAKE_LIVE_BIN"
  SB_FAKE_LIVE_PORT=$(free_port 22800);        export SB_FAKE_LIVE_PORT
  SB_FAKE_LIVE_CLASH_PORT=$(free_port 22900);  export SB_FAKE_LIVE_CLASH_PORT
  # 系统 DNS 已在代理模式（= PROXY_DNS）。不这样的话 cmd_start -y 自己就会去写 DNS，
  # 「DNS 没被改」这条断言在默认装置下恒红，测不到 --keep-dns 漏没漏。
  export SB_FAKE_DNS=1.1.1.1
  echo 1 > "$SB_FAKE_STATE/running"          # 现网服务在跑
  echo 1 > "$SB_FAKE_STATE/loaded"
  : > "$SB_FAKE_STATE/btm_events"
  : > "$SB_FAKE_STATE/dns_events"
  python3 -c 'import socket,sys,time
socks=[]
for a in sys.argv[1:]:
    s=socket.socket(); s.bind(("127.0.0.1",int(a))); s.listen(16); socks.append(s)
time.sleep(600)' "$SB_FAKE_LIVE_PORT" "$SB_FAKE_LIVE_CLASH_PORT" >/dev/null 2>&1 &
  echo $! > "$SB_FAKE_STATE/listener.pid"
  disown $! 2>/dev/null   # teardown 杀它时不要打「Terminated: 15」
  local w
  for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    port_busy "$SB_FAKE_LIVE_PORT" && break
    /bin/sleep 0.1
  done
  if ! port_busy "$SB_FAKE_LIVE_PORT"; then
    printf '  FAIL  装置失败：现网监听没起来（%s）\n' "$SB_FAKE_LIVE_PORT"
    exit 1
  fi

  write_cfg rel 1
  printf 'old-cache-%s' "$RANDOM" > "$(ETC)/cache.db"
  export SB_FAKE_CACHE_DB="$(ETC)/cache.db"

  unset SB_FAKE_RULE_FAIL SB_FAKE_PROBE_FAIL SB_FAKE_NOCACHE_FAIL SB_FAKE_CLASH_SECRET \
        SB_FAKE_START_FAIL SB_FAKE_DAEMON_LOADED SB_FAKE_BTM_PIN
}

teardown() {
  [ -n "${SB_FAKE_STATE:-}" ] && [ -s "$SB_FAKE_STATE/listener.pid" ] && \
    kill "$(cat "$SB_FAKE_STATE/listener.pid")" 2>/dev/null
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf "${SB_LOCKDIR:-/tmp/.singbox-sh.lock}" 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# sb <子命令…> —— 跑一次 singbox.sh，退出码进 $CODE
sb() { PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" >"$LOG" 2>&1; CODE=$?; }

events() { tr '\n' ' ' < "$SB_FAKE_STATE/btm_events" 2>/dev/null; }
booted_out() { grep -q '^bootout$' "$SB_FAKE_STATE/btm_events" 2>/dev/null; }

echo "验证 rules 与 rules update"

#-- AC8 不带参数的 rules：行为不变 ----------------------------------------
setup
sb rules
if [ "$CODE" = 0 ] && grep -q '全部 2 个规则集可达' "$LOG" && ! booted_out; then
  ok "rules（无参数）：只验 URL，全部可达退 0，不碰服务"
else
  ng "rules（无参数）：期望退 0 且报全部 2 个可达（退出 ${CODE}）" "$(events)"
fi

#-- AC8 未知参数 ------------------------------------------------------------
setup
sb rules foo
if [ "$CODE" != 0 ] && grep -q 'foo' "$LOG" && ! booted_out; then
  ok "rules foo：报未知参数并非 0 退出"
else
  ng "rules foo：期望非 0 且点名 foo（退出 ${CODE}）"
fi

#-- AC8 help 列出 rules update ---------------------------------------------
setup
sb help
if [ "$CODE" = 0 ] && grep -q '^  rules update' "$LOG"; then
  ok "help 列出 rules update"
else
  ng "help：期望有一行以「  rules update」开头"
fi

#-- AC2 预检有一个不通：不动服务 -------------------------------------------
setup
before=$(sig "$(ETC)/cache.db")
SB_FAKE_RULE_FAIL=geoip-cn sb rules update
if [ "$CODE" = 1 ] && ! booted_out && [ "$(sig "$(ETC)/cache.db")" = "$before" ] \
   && [ ! -e "$(ETC)/cache.db.prev" ] && grep -q 'geoip-cn' "$LOG"; then
  ok "预检 404：退 1，没有 bootout，缓存不动，点名 geoip-cn"
else
  ng "预检 404：期望退 1、无 bootout、缓存不动、点名 geoip-cn（退出 ${CODE}）" "$(events)"
fi

#-- AC4 服务没在运行：拒绝 -------------------------------------------------
setup
echo 0 > "$SB_FAKE_STATE/running"
before=$(sig "$(ETC)/cache.db")
sb rules update
if [ "$CODE" != 0 ] && ! booted_out && [ "$(sig "$(ETC)/cache.db")" = "$before" ] \
   && grep -q 'start' "$LOG"; then
  ok "服务未运行：拒绝并提示 start，没有 bootout，缓存不动"
else
  ng "服务未运行：期望非 0、提示 start、无 bootout（退出 ${CODE}）" "$(events)"
fi

#-- AC6 cache_file 没开：拒绝 ----------------------------------------------
setup
write_cfg off 1
before=$(sig "$(ETC)/cache.db")
sb rules update
if [ "$CODE" != 0 ] && ! booted_out && [ "$(sig "$(ETC)/cache.db")" = "$before" ] \
   && grep -q 'restart' "$LOG"; then
  ok "cache_file 未开启：拒绝并提示 restart，没有 bootout"
else
  ng "cache_file 未开启：期望非 0、提示 restart、无 bootout（退出 ${CODE}）" "$(events)"
fi

#-- AC7 --dry-run：只打印计划 ----------------------------------------------
setup
before=$(sig "$(ETC)/cache.db")
sb -n rules update
if [ "$CODE" = 0 ] && ! booted_out && [ "$(sig "$(ETC)/cache.db")" = "$before" ] \
   && [ ! -e "$(ETC)/cache.db.prev" ]; then
  ok "--dry-run：退 0，没有 bootout，缓存不动"
else
  ng "--dry-run：期望退 0、无 bootout、缓存不动（退出 ${CODE}）" "$(events)"
fi

#-- AC1 正常路径：停 → 移走缓存 → 起，起的那一刻缓存不在 ----------------
setup
orig=$(cat "$(ETC)/cache.db")
sb rules update
if [ "$CODE" = 0 ] && events | grep -q 'bootout bootstrap:[^ ]* cache:absent' \
   && ! grep -q '^cache:present$' "$SB_FAKE_STATE/btm_events" \
   && [ "$(cat "$(ETC)/cache.db.prev" 2>/dev/null)" = "$orig" ] \
   && [ "$(cat "$(ETC)/cache.db" 2>/dev/null)" = fresh-cache ] \
   && [ "$(cat "$SB_FAKE_STATE/running")" = 1 ] && [ ! -s "$SB_FAKE_STATE/dns_events" ]; then
  ok "正常路径：退 0，bootstrap 时 cache.db 不在，.prev 是原缓存，DNS 没动"
else
  ng "正常路径：期望退 0、bootout 后 cache:absent、.prev = 原缓存、DNS 无写入（退出 ${CODE}）" \
     "$(events) | dns: $(tr '\n' ' ' < "$SB_FAKE_STATE/dns_events" 2>/dev/null)"
fi

#-- AC3 无缓存起不来：换回旧缓存再起 -------------------------------------
setup
orig=$(cat "$(ETC)/cache.db")
SB_FAKE_NOCACHE_FAIL=1 sb rules update
if [ "$CODE" = 1 ] && [ "$(cat "$SB_FAKE_STATE/running")" = 1 ] \
   && [ "$(cat "$(ETC)/cache.db" 2>/dev/null)" = "$orig" ] \
   && events | grep -q 'cache:absent .*bootout bootstrap:[^ ]* cache:present'; then
  ok "无缓存起不来：换回旧缓存再起，服务在跑，缓存是原内容，退 1"
else
  ng "无缓存起不来：期望退 1、服务在跑、cache.db = 原内容、第二次 bootstrap 有缓存（退出 ${CODE}）" "$(events)"
fi

#-- AC6 缓存路径以配置为准：自定义绝对路径 ------------------------------
setup
mkdir -p "$ROOT/custom"
write_cfg "abs:$ROOT/custom/c.db" 1
printf 'custom-old' > "$ROOT/custom/c.db"
export SB_FAKE_CACHE_DB="$ROOT/custom/c.db"
etc_before=$(sig "$(ETC)/cache.db")
sb rules update
if [ "$CODE" = 0 ] && [ "$(cat "$ROOT/custom/c.db.prev" 2>/dev/null)" = custom-old ] \
   && [ ! -e "$(ETC)/cache.db.prev" ] && [ "$(sig "$(ETC)/cache.db")" = "$etc_before" ]; then
  ok "自定义 cache_file.path：移走的是那个文件，\$ETC/cache.db 没被碰"
else
  ng "自定义 cache_file.path：期望 c.db.prev = 原内容、\$ETC 下无 .prev（退出 ${CODE}）" "$(events)"
fi

#-- AC6 没写 path：默认 $ETC/cache.db ------------------------------------
setup
write_cfg nopath 1
orig=$(cat "$(ETC)/cache.db")
sb rules update
if [ "$CODE" = 0 ] && [ "$(cat "$(ETC)/cache.db.prev" 2>/dev/null)" = "$orig" ]; then
  ok "cache_file 没写 path：按 \$ETC/cache.db 处理"
else
  ng "cache_file 没写 path：期望 \$ETC/cache.db.prev = 原缓存（退出 ${CODE}）" "$(events)"
fi

#-- AC5 clash 模式：更新前是 Global，更新后仍是 Global ---------------------
# 无缓存起服会把模式打回默认（假 launchctl 删 clash_mode）——不写回，这里读到的就是空。
# secret 要求对上：请求不带 Bearer 会被拒，GET 读不到，同样写不回。
setup
echo Global > "$SB_FAKE_STATE/clash_mode"
export SB_FAKE_CLASH_SECRET=s3cret
sb rules update
if [ "$CODE" = 0 ] && [ "$(cat "$SB_FAKE_STATE/clash_mode" 2>/dev/null)" = Global ] \
   && grep -q '^PATCH:Global$' "$SB_FAKE_STATE/clash_events" 2>/dev/null; then
  ok "clash 模式：更新前 Global，更新后写回 Global（带 secret）"
else
  ng "clash 模式：期望退 0、mode 仍是 Global 且 PATCH 过（退出 ${CODE}，mode=$(cat "$SB_FAKE_STATE/clash_mode" 2>/dev/null)）" \
     "$(tr '\n' ' ' 2>/dev/null < "$SB_FAKE_STATE/clash_events")"
fi

#-- AC5 没开 clash_api：不发请求，只打一行跳过 ---------------------------
setup
write_cfg rel 0
sb rules update
if [ "$CODE" = 0 ] && [ ! -s "$SB_FAKE_STATE/clash_events" ] && grep -q 'clash_api.*跳过' "$LOG"; then
  ok "没开 clash_api：不请求 /configs，打一行跳过"
else
  ng "没开 clash_api：期望退 0、无 /configs 请求、日志有跳过提示（退出 ${CODE}）"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
