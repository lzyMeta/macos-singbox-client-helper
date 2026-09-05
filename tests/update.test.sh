#!/usr/bin/env bash
#
# tests/update.test.sh —— cmd_update 四阶段 / cmd_rollback 的状态机断言。
#
# 全程离线、不要 sudo、不碰真实系统：tests/fixtures/bin 前置到 PATH，
# --prefix 指到临时目录，假内核由 tests/fixtures/fake-sing-box 实例化而来。
#
# 每条断言盯的是**同一件事的两面**：升级成功时新内核在位、且退路（.prev）还在；
# 升级失败时现网必须回到一个已知可用的状态。阶段 1 的两条尤其严格——那时候
# 现网服务还在跑，$BIN 连碰都不该被碰一下。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB=./singbox.sh
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"
OLD=1.13.18
NEW=1.13.19            # 同 minor：不触发跨 minor 那道额外确认
NEWMINOR=1.14.0

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -25 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

# 把假内核装到某个路径上，版本号烧进去
mk_bin() { sed "s/__VERSION__/$2/" "$FAKE" > "$1"; chmod 755 "$1"; }

# 读某个二进制自报的版本；文件不存在则输出空
bin_version() { [ -x "$1" ] && "$1" version 2>/dev/null | head -1 | awk '{print $3}'; }

sig() { [ -f "$1" ] && shasum "$1" | awk '{print $1}'; }

# 从 $1 起找一个真正空闲的端口。⚠️ 不要写死 10808：这台机器上很可能正跑着真的
# sing-box，撞上之后桩的监听 bind 失败即死，而「端口在听」照样成立——测试会因为
# 真实服务而变绿，测不到任何东西。
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

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state";  mkdir -p "$SB_FAKE_STATE"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"

  export SB_FAKE_LIVE_BIN="$ROOT/prefix/bin/sing-box"
  SB_FAKE_LIVE_PORT=$(free_port 21800);        export SB_FAKE_LIVE_PORT
  SB_FAKE_LIVE_CLASH_PORT=$(free_port 21900);  export SB_FAKE_LIVE_CLASH_PORT
  export SB_FAKE_LATEST="${1:-$NEW}"
  echo 1 > "$SB_FAKE_STATE/running"          # 现网服务在跑
  echo 0 > "$SB_FAKE_STATE/verify_calls"
  # ⚠️ 光写状态位不够：阶段 1 跑的时候必须真的有进程占着现网的监听端口，
  # 否则「沙箱与现网撞车」这类断言就是假绿——撞不上，因为压根没人占。
  python3 -c 'import socket,sys,time
socks=[]
for a in sys.argv[1:]:
    s=socket.socket(); s.bind(("127.0.0.1",int(a))); s.listen(16); socks.append(s)
time.sleep(600)' "$SB_FAKE_LIVE_PORT" "$SB_FAKE_LIVE_CLASH_PORT" >/dev/null 2>&1 &
  echo $! > "$SB_FAKE_STATE/listener.pid"
  local w
  for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    port_busy "$SB_FAKE_LIVE_PORT" && break
    /bin/sleep 0.1
  done
  # ⚠️ 装置起不来必须当场炸。静默放过的话，后面每一条断言都在测一个不存在的现网。
  if ! kill -0 "$(cat "$SB_FAKE_STATE/listener.pid")" 2>/dev/null \
     || ! port_busy "$SB_FAKE_LIVE_PORT" || ! port_busy "$SB_FAKE_LIVE_CLASH_PORT"; then
    printf '  FAIL  装置失败：现网监听没起来（%s / %s）\n' \
      "$SB_FAKE_LIVE_PORT" "$SB_FAKE_LIVE_CLASH_PORT"
    exit 1
  fi

  # 现网配置：tun + mixed:10808 + cache_file —— 派生逻辑要处理的三处冲突齐了
  cat > "$ROOT/prefix/etc/sing-box/config.json" <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "interface_name": "utun4",
      "address": ["172.19.0.1/30"], "auto_route": true },
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
      "listen_port": ${SB_FAKE_LIVE_PORT} }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "experimental": {
    "cache_file": { "enabled": true, "path": "/usr/local/etc/sing-box/cache.db" },
    "clash_api": { "external_controller": "127.0.0.1:${SB_FAKE_LIVE_CLASH_PORT}",
                   "external_ui": "monitor" }
  }
}
JSON

  mk_bin "$SB_FAKE_LIVE_BIN" "$OLD"

  # 打一个和 GitHub 上同构的 tar.gz：sing-box-<版本>-darwin-<arch>/sing-box
  local arch; arch=$([ "$(uname -m)" = arm64 ] && echo arm64 || echo amd64)
  local d="$ROOT/pkg/sing-box-${SB_FAKE_LATEST}-darwin-${arch}"
  mkdir -p "$d"; mk_bin "$d/sing-box" "$SB_FAKE_LATEST"
  ( cd "$ROOT/pkg" && tar czf "$ROOT/kernel.tar.gz" "sing-box-${SB_FAKE_LATEST}-darwin-${arch}" )
  export SB_FAKE_TARBALL="$ROOT/kernel.tar.gz"

  unset SB_FAKE_CHECK_FAIL SB_FAKE_RUN_FAIL SB_FAKE_START_FAIL \
        SB_FAKE_SANDBOX_SOCKS_FAIL SB_FAKE_VERIFY_FAIL SB_FAKE_NO_TUN \
        SB_FAKE_PROBE_FAIL SB_FAKE_DEPRECATED SB_FAKE_TUN_HOST_ONLY
}

teardown() {
  [ -n "${SB_FAKE_STATE:-}" ] && [ -s "$SB_FAKE_STATE/listener.pid" ] && \
    kill "$(cat "$SB_FAKE_STATE/listener.pid")" 2>/dev/null
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf /tmp/.singbox-sh.lock 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# sb <子命令…> —— 跑一次 singbox.sh，退出码进 $CODE
sb() { PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" >"$LOG" 2>&1; CODE=$?; }

BIN() { printf '%s' "$ROOT/prefix/bin/sing-box"; }

echo "验证 cmd_update 的四阶段状态机与 cmd_rollback"

#-- 1. 一切正常 ---------------------------------------------------------
setup
sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ] \
   && [ "$(bin_version "$(BIN).prev")" = "$OLD" ]; then
  ok "一切正常：退出 0，新内核在位，.prev 保留了旧版本"
else
  ng "一切正常：期望 0/${NEW}/${OLD}，实际 ${CODE}/$(bin_version "$(BIN)")/$(bin_version "$(BIN).prev")"
fi

#-- 2. 阶段 1 沙箱 check -c 失败：现网一个字节都不该被动 -----------------
setup
before=$(sig "$(BIN)")
SB_FAKE_CHECK_FAIL="sandbox:$NEW" sb update
if [ "$CODE" != 0 ] && [ "$(sig "$(BIN)")" = "$before" ] && [ ! -e "$(BIN).prev" ]; then
  ok "阶段 1 check 失败：非 0 退出，\$BIN 未被触碰，没有产生 .prev"
else
  ng "阶段 1 check 失败：期望非 0 且 \$BIN 原封不动（退出 ${CODE}，.prev 存在=$([ -e "$(BIN).prev" ] && echo 是 || echo 否)）"
fi

#-- 3. 阶段 1 沙箱建链失败：同上 ----------------------------------------
setup
before=$(sig "$(BIN)")
SB_FAKE_SANDBOX_SOCKS_FAIL=1 sb update
if [ "$CODE" != 0 ] && [ "$(sig "$(BIN)")" = "$before" ] && [ ! -e "$(BIN).prev" ]; then
  ok "阶段 1 建链失败：非 0 退出，现网完全没被触碰"
else
  ng "阶段 1 建链失败：期望非 0 且 \$BIN 原封不动（退出 ${CODE}）"
fi

#-- 4. 阶段 2 check -c 失败：回滚 ---------------------------------------
setup
SB_FAKE_CHECK_FAIL="live:$NEW" sb update
if [ "$CODE" != 0 ] && [ "$(bin_version "$(BIN)")" = "$OLD" ] && [ ! -e "$(BIN).prev" ]; then
  ok "阶段 2 check 失败：已回滚到旧版本，.prev 被清理"
else
  ng "阶段 2 check 失败：期望非 0 且回到 ${OLD}（退出 ${CODE}，实际 $(bin_version "$(BIN)")）"
fi

#-- 5. 阶段 2 起不来：回滚（现在的实现拓不到这条）------------------------
setup
SB_FAKE_START_FAIL="$NEW" sb update
if [ "$CODE" != 0 ] && [ "$(bin_version "$(BIN)")" = "$OLD" ]; then
  ok "阶段 2 起不来：已回滚到旧版本"
else
  ng "阶段 2 起不来：期望非 0 且回到 ${OLD}（退出 ${CODE}，实际 $(bin_version "$(BIN)")）"
fi

#-- 6. 阶段 3 两轮都失败：回滚 ------------------------------------------
setup
SB_FAKE_VERIFY_FAIL=all sb update
if [ "$CODE" != 0 ] && [ "$(bin_version "$(BIN)")" = "$OLD" ]; then
  ok "阶段 3 两轮都败：已回滚到旧版本"
else
  ng "阶段 3 两轮都败：期望非 0 且回到 ${OLD}（退出 ${CODE}，实际 $(bin_version "$(BIN)")）"
fi

#-- 7. 阶段 3 第一轮败、第二轮过：不回滚（防误判的正控）------------------
setup
SB_FAKE_VERIFY_FAIL=first sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ]; then
  ok "阶段 3 第一轮败第二轮过：不回滚，退出 0"
else
  ng "阶段 3 重试：期望 0/${NEW}，实际 ${CODE}/$(bin_version "$(BIN)")"
fi

#-- 8. 跨 minor 且非交互：不升级 ----------------------------------------
setup "$NEWMINOR"
before=$(sig "$(BIN)")
sb update
if [ "$CODE" = 0 ] && [ "$(sig "$(BIN)")" = "$before" ] && [ ! -e "$(BIN).prev" ]; then
  ok "跨 minor 非交互：不升级，退出 0，\$BIN 未变"
else
  ng "跨 minor 非交互：期望 0 且 \$BIN 停在 ${OLD}（退出 ${CODE}，实际 $(bin_version "$(BIN)")）"
fi

#-- 9. rollback 有 .prev -----------------------------------------------
setup
sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ]; then
  sb rollback
  if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$OLD" ]; then
    ok "rollback 有 .prev：换回旧版本并重启"
  else
    ng "rollback 有 .prev：期望 0/${OLD}，实际 ${CODE}/$(bin_version "$(BIN)")"
  fi
else
  ng "rollback 有 .prev：前置的 update 就没成功（退出 ${CODE}）"
fi

#-- 11. 沙箱不与现网的 clash_api 端口撞车 -------------------------------
# 真实配置里 experimental.clash_api.external_controller 是第四处会撞的监听
# （spec 只列了 tun / mixed / cache_file 三处）。现网实例占着它，派生配置
# 若原样留着 clash_api，沙箱实例就起不来——而这跟新内核好不好毫无关系。
setup
sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ] \
   && ! grep -q '沙箱实例没能起来' "$LOG"; then
  ok "沙箱避开了现网的 clash_api 端口（${SB_FAKE_LIVE_CLASH_PORT}）"
else
  ng "沙箱撞上了现网的 clash_api 端口：派生配置该把 clash_api 去掉（退出 ${CODE}）"
fi

#-- 12. TUN 接口在、但流量没被接管：必须回滚 ----------------------------
# 路由表里出现 utun 不等于 TUN 接管了流量。真机上 utun9527 有 9 条路由，
# 只有 128.0/1 那条是接管的证据；172.18.0.1 … UH 只说明接口建起来了。
# 宽匹配整张表会把「接口在、流量从 en0 裸奔」判成健康——正是本功能要挡的故障。
setup
SB_FAKE_TUN_HOST_ONLY=1 sb update
if [ "$CODE" != 0 ] && [ "$(bin_version "$(BIN)")" = "$OLD" ]; then
  ok "TUN 只剩主机路由：判为不健康并回滚"
else
  ng "TUN 只剩主机路由：期望非 0 且回到 ${OLD}（退出 ${CODE}，实际 $(bin_version "$(BIN)")）"
fi

#-- 10. rollback 无 .prev ----------------------------------------------
setup
before=$(sig "$(BIN)")
sb rollback
# 「未知命令」也会非 0 退出且不动文件——那是假绿。必须确认它是因为**没有回滚点**
# 而失败，而不是因为压根没有 rollback 这个子命令。
if [ "$CODE" != 0 ] && [ "$(sig "$(BIN)")" = "$before" ] \
   && ! grep -q '未知命令' "$LOG" && grep -q 'prev' "$LOG"; then
  ok "rollback 无 .prev：因缺回滚点而报错退出，不动任何东西"
else
  ng "rollback 无 .prev：期望非 0、点名 .prev、且 \$BIN 不变（退出 ${CODE}）"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
