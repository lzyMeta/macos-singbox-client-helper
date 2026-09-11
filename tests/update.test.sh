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
SB="${SB_UNDER_TEST:-./singbox.sh}"   # 换成旧版脚本即可验证某条断言不是恒绿的
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

  # ⚠️ 阶段 3 的验收会跑 cmd_verify 第 4 步，那一步是自己发 UDP 包的真探测。
  # 不钉死结果的话，这里每条用例都会去连公网：联网时判「QUIC 未阻断」→ 阶段 3
  # 变成策略档失败，离线时白等两个超时。
  export SB_FAKE_QUIC=blocked
  # 同理钉死 UDP 对照组：QUIC=blocked 之后 verify 第 4 步会走到 _sb_udp_alive，
  # 不钉的话这里照样会往公网发 UDP，离线跑测试就是假红。
  export SB_FAKE_UDP=alive

  unset SB_FAKE_BAD_SHA SB_FAKE_NO_DIGEST
  unset SB_FAKE_CHECK_FAIL SB_FAKE_RUN_FAIL SB_FAKE_START_FAIL \
        SB_FAKE_SANDBOX_SOCKS_FAIL SB_FAKE_VERIFY_FAIL SB_FAKE_NO_TUN \
        SB_FAKE_PROBE_FAIL SB_FAKE_DEPRECATED SB_FAKE_TUN_HOST_ONLY \
        SB_FAKE_DIG_FAIL SB_FAKE_NO_GW SB_FAKE_PING_FAIL SB_FAKE_CN_FAIL
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

#-- 6. 阶段 3 两轮都失败：回滚（链路档，与下面第 13 条正好是分档的两半）------
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

#-- 13. 阶段 3 只有策略档失败：不回滚 ------------------------------------
# 「分档」这个决定唯一能被机械证伪的地方。QUIC 没被挡住是路由策略问题，
# 换回旧内核一个字都改不了——真回滚了，等于每次 update 都被一条修不好的
# 检查项撤销掉。要求：退出 0、新内核在位、.prev 还在、日志里说清了为什么放行。
setup
SB_FAKE_QUIC=open sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ] \
   && [ "$(bin_version "$(BIN).prev")" = "$OLD" ] \
   && grep -q '策略档' "$LOG"; then
  ok "阶段 3 仅策略档失败：不回滚，退出 0，新内核与 .prev 都在"
else
  ng "阶段 3 仅策略档失败：期望 0/${NEW}/${OLD} 且日志点名策略档（实际 ${CODE}/$(bin_version "$(BIN)")/$(bin_version "$(BIN).prev")）"
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

#-- 14. -n update：一个字节都不该落地 ------------------------------------
# 改动之前 cmd_update 完全不看 $DRY：-n 会真的下载、真的换掉 $BIN、真的重启服务，
# 而 ask() 在 DRY=1 时又是直接取默认值（升级确认默认就是 y），一个确认点都不停。
setup
before=$(sig "$(BIN)")
sb -n update
if [ "$CODE" = 0 ] && [ "$(sig "$(BIN)")" = "$before" ] && [ ! -e "$(BIN).prev" ] \
   && grep -q "dry-run" "$LOG"; then
  ok "-n update：退出 0，\$BIN 一个字节没动，没有产生 .prev"
else
  ng "-n update：期望 0 且 \$BIN 原封不动（退出 ${CODE}，.prev 存在=$([ -e "$(BIN).prev" ] \
      && echo 是 || echo 否)）"
fi

#-- 15. -n rollback：同样不该落地 ----------------------------------------
setup
sb update                       # 先制造一个 .prev
before=$(sig "$(BIN)")
beforeprev=$(sig "$(BIN).prev")
sb -n rollback
if [ "$CODE" = 0 ] && [ "$(sig "$(BIN)")" = "$before" ] \
   && [ "$(sig "$(BIN).prev")" = "$beforeprev" ]; then
  ok "-n rollback：退出 0，\$BIN 与 .prev 都原封不动"
else
  ng "-n rollback：期望两个文件都不变（退出 ${CODE}）"
fi

#-- 16. 下载物 sha256 对不上：必须当场死，不能装上去 ----------------------
# 直连 github 拿到的都对不上就没有再试下去的意义了，且绝不能 sudo install。
setup
before=$(sig "$(BIN)")
SB_FAKE_BAD_SHA=1 sb update
if [ "$CODE" != 0 ] && [ "$(sig "$(BIN)")" = "$before" ] \
   && grep -q "sha256 不匹配" "$LOG"; then
  ok "sha256 对不上：非 0 退出，\$BIN 未被触碰"
else
  ng "sha256 对不上：期望非 0 且 \$BIN 原封不动（退出 ${CODE}）"
fi

#-- 17. asset 没有 digest 字段：降级放行，不是硬失败 ----------------------
# 老 release 就是这个形态。校验不了要说清楚，但不该把升级堵死。
setup
SB_FAKE_NO_DIGEST=1 sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ] \
   && grep -q "不做完整性校验" "$LOG"; then
  ok "asset 无 digest：警告后照常升级，退出 0"
else
  ng "asset 无 digest：期望 0 且升级完成（退出 ${CODE}）"
fi

#-- 18. 正常路径确实做了校验（别让上面那条降级把校验整个绕过去）-----------
setup
sb update
if [ "$CODE" = 0 ] && grep -q "sha256 校验通过" "$LOG"; then
  ok "正常路径：日志里有「sha256 校验通过」，校验确实跑了"
else
  ng "正常路径：期望日志出现「sha256 校验通过」（退出 ${CODE}）"
fi

#-- 19. rollback 同时退内核与启动器 --------------------------------------
# 两者各有各的 .prev，退路是独立的。只退内核而不退命令，下次跑的仍是新脚本 ——
# 等于只退了一半，而终端上完全看不出来。
setup
LAUNCHER="$ROOT/prefix/bin/singbox"
sb update                                        # 先制造内核的 .prev
printf '#!/usr/bin/env bash\necho 旧启动器\n' > "$LAUNCHER.prev"
printf '#!/usr/bin/env bash\necho 新启动器\n' > "$LAUNCHER"
chmod 755 "$LAUNCHER" "$LAUNCHER.prev"
oldlauncher=$(sig "$LAUNCHER.prev")
sb rollback
if [ "$(bin_version "$(BIN)")" = "$OLD" ] \
   && [ "$(sig "$LAUNCHER")" = "$oldlauncher" ] && [ ! -e "$LAUNCHER.prev" ]; then
  ok "rollback：内核与 singbox 命令一起退回上一版"
else
  ng "rollback：期望启动器也退回（内核=$(bin_version "$(BIN)")，.prev 还在=$([ -e "$LAUNCHER.prev" ] \
      && echo 是 || echo 否)）"
fi

#-- 20. 只有内核有 .prev、启动器没有：只退内核，并说明它没有退路 ----------
setup
LAUNCHER="$ROOT/prefix/bin/singbox"
sb update
printf '#!/usr/bin/env bash\necho 新启动器\n' > "$LAUNCHER"
chmod 755 "$LAUNCHER"
before=$(sig "$LAUNCHER")
sb rollback
if [ "$(bin_version "$(BIN)")" = "$OLD" ] && [ "$(sig "$LAUNCHER")" = "$before" ] \
   && grep -qF "没有退路" "$LOG"; then
  ok "rollback 启动器无 .prev：只退内核，且说明了命令没有退路"
else
  ng "rollback 启动器无 .prev：期望内核退回、启动器不变、日志说明（内核=$(bin_version "$(BIN)")）"
fi

#-- 21. 阶段 3 之后的配置审查：只报，不影响退出码与回滚判定 ----------------
# 内核版本一变，废弃面和 schema 跟着变 —— 这是最该重查配置的时刻。但它只报不改，
# 也不参与成败判定：配置「将来会坏」不等于这次升级失败了，判错就是白白回滚一次
# 好端端的升级。
setup
# 用 store_rdrc（check 档抓得到）而不是 download_detour：后者只有 schema 档看得见，
# 而 schema 档在 < 1.14.0 的内核上被版本闸门关掉，这条用例升的是 1.13.19。
python3 - "$ROOT/prefix/etc/sing-box/config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("experimental", {})["cache_file"] = {
    "enabled": True, "store_rdrc": True,
    "path": "/usr/local/etc/sing-box/cache.db"}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PY
sb update
if [ "$CODE" = 0 ] && [ "$(bin_version "$(BIN)")" = "$NEW" ]; then
  ok "配置有废弃项：update 照样退 0，新内核在位（没被误判成失败）"
else
  ng "配置有废弃项：期望 0/${NEW}，实际 ${CODE}/$(bin_version "$(BIN)")"
fi
if grep -q '废弃/未知字段' "$LOG"; then
  ok "阶段 3 之后跑了配置审查并报出废弃项"
else
  ng "阶段 3 之后没跑配置审查 —— 挂载点没生效"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
