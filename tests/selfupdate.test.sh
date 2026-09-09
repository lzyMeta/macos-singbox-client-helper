#!/usr/bin/env bash
#
# tests/selfupdate.test.sh —— cmd_update 阶段 S（脚本更新自己）的状态机。
#
# 全程离线、不要 sudo、不碰真实系统：tests/fixtures/bin 前置到 PATH，
# --prefix 指到临时目录。
#
# 判据始终是**两面**：该换的时候换了、且旧的那份有退路；不该换的时候
# $LAUNCHER 的 sha256 一个 bit 都不许变。「不该换」有三种，而它们在终端上
# 长得一模一样，只有 sha 能把它们和「换了但没说」分开：
#   远端 == 本地、远端 < 本地（release 被回退，绝不许降级）、下载物语法不过。
#
# ⚠️ 内核那几个阶段一律用「远端内核版本 == 已装版本」早退在阶段 0，
# 这样不必架沙箱与现网监听。判据是日志里的「已是最新」—— 它证明阶段 S
# 之后确实走到了内核阶段，而不是把整条 update 堵死了。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"   # 换成变异版即可验证某条断言不是恒绿的
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"
KVER=1.13.18           # 已装内核版本；远端也报这个，于是阶段 0 早退

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -25 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

mk_bin() { sed "s/__VERSION__/$2/" "$FAKE" > "$1"; chmod 755 "$1"; }
sig() { [ -f "$1" ] && shasum "$1" | awk '{print $1}'; }

LAUNCHER() { printf '%s' "$ROOT/prefix/bin/singbox"; }

# 本地脚本自报的版本号 —— 断言「远端更高 / 相等 / 更低」都要围着它构造
LOCAL_VER=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$SB" | head -1)

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state";  mkdir -p "$SB_FAKE_STATE"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"

  export SB_FAKE_LIVE_BIN="$ROOT/prefix/bin/sing-box"
  export SB_FAKE_LATEST="$KVER"          # 内核：远端 == 本地 → 阶段 0 早退
  mk_bin "$ROOT/prefix/bin/sing-box" "$KVER"
  echo '{ "inbounds": [], "outbounds": [] }' > "$ROOT/prefix/etc/sing-box/config.json"

  # 「远端那份新脚本」。被 exec 时把关键环境变量与参数写进标记文件 ——
  # 这是「确实换了进程」唯一不可伪造的证据。
  export SB_SELF_MARKER="$ROOT/exec-marker"
  cat > "$ROOT/new-singbox.sh" <<'NEWEOF'
#!/usr/bin/env bash
VERSION="9.9.9"
printf 'SB_SELF_UPDATED=%s\nSB_LOCK_INHERIT=%s\nARGV=%s\n' \
  "${SB_SELF_UPDATED:-}" "${SB_LOCK_INHERIT:-}" "$*" > "${SB_SELF_MARKER:?}"
exit 0
NEWEOF
  chmod 755 "$ROOT/new-singbox.sh"

  # 语法坏掉的那一份，用来钉住「bash -n 不过就不替换」
  printf '#!/usr/bin/env bash\nVERSION="9.9.9"\nif [ 1 = 1 ; then echo broken\n' \
    > "$ROOT/broken-singbox.sh"
  chmod 755 "$ROOT/broken-singbox.sh"

  export SB_FAKE_SELF_SCRIPT="$ROOT/new-singbox.sh"
  unset SB_FAKE_SELF_LATEST SB_SELF_UPDATED SB_LOCK_INHERIT \
        SB_FAKE_PROBE_FAIL SB_FAKE_BAD_SHA SB_FAKE_NO_DIGEST SB_FAKE_SELF_BAD_SHA
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf /tmp/.singbox-sh.lock 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# 把当前这份脚本装成启动器 —— re-exec 那条路只有从 $LAUNCHER 启动才会走
put_launcher() { cp "$SB" "$(LAUNCHER)"; chmod 755 "$(LAUNCHER)"; }

# 从仓库副本跑
sb_repo() {
  PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y update >"$LOG" 2>&1; CODE=$?
}
# 从 $LAUNCHER 跑
sb_launcher() {
  PATH="$FIXBIN:$PATH" "$(LAUNCHER)" --prefix "$ROOT/prefix" -y update >"$LOG" 2>&1; CODE=$?
}

echo "验证 cmd_update 阶段 S（脚本自更新）"

#-- 5. 远端 > 本地：换掉、旧的进 .prev，且确实 exec 了新进程 --------------
setup
export SB_FAKE_SELF_LATEST=9.9.9
put_launcher
oldsig=$(sig "$(LAUNCHER)")
sb_launcher
if [ "$(sig "$(LAUNCHER)")" = "$(sig "$ROOT/new-singbox.sh")" ] \
   && [ "$(sig "$(LAUNCHER).prev")" = "$oldsig" ] \
   && [ -f "$SB_SELF_MARKER" ] \
   && grep -q '^SB_SELF_UPDATED=1$' "$SB_SELF_MARKER" \
   && grep -q '^SB_LOCK_INHERIT=1$' "$SB_SELF_MARKER"; then
  ok "远端更新：启动器换成远端内容，旧的进 .prev，新进程被 exec 且两个环境变量都传到了"
else
  ng "远端更新：期望换掉 + .prev + exec 标记（标记=$([ -f "$SB_SELF_MARKER" ] && cat "$SB_SELF_MARKER" | tr '\n' ' ' || echo 无)）"
fi

#-- 6. 远端 == 本地：一个 bit 都不许动 -----------------------------------
setup
export SB_FAKE_SELF_LATEST="$LOCAL_VER"
put_launcher
before=$(sig "$(LAUNCHER)")
sb_launcher
if [ "$(sig "$(LAUNCHER)")" = "$before" ] && [ ! -e "$(LAUNCHER).prev" ] \
   && [ ! -f "$SB_SELF_MARKER" ] && grep -q "已是最新" "$LOG"; then
  ok "远端 == 本地：启动器 sha256 不变，没有 exec，照常进内核阶段"
else
  ng "远端 == 本地：期望不动且继续走内核阶段（退出 ${CODE}）"
fi

#-- 7. 远端 < 本地：绝不降级 ---------------------------------------------
# release 被回退时把用户的脚本降回去，等于把已修的 bug 又装回来。
setup
export SB_FAKE_SELF_LATEST=0.0.1
put_launcher
before=$(sig "$(LAUNCHER)")
sb_launcher
if [ "$(sig "$(LAUNCHER)")" = "$before" ] && [ ! -e "$(LAUNCHER).prev" ] \
   && [ ! -f "$SB_SELF_MARKER" ]; then
  ok "远端 < 本地：不降级，启动器 sha256 不变"
else
  ng "远端 < 本地：期望不降级（退出 ${CODE}）"
fi

#-- 8. 取不到远端版本：warn 一句，内核阶段照跑 ---------------------------
# 脚本更新不该有权阻断用户真正要的那件事，何况内核升级自带沙箱与回滚。
setup
unset SB_FAKE_SELF_LATEST          # 自家 repo 一个 release 都没有
put_launcher
before=$(sig "$(LAUNCHER)")
sb_launcher
if [ "$CODE" = 0 ] && [ "$(sig "$(LAUNCHER)")" = "$before" ] \
   && grep -q "取不到脚本的最新版本" "$LOG" && grep -q "已是最新" "$LOG"; then
  ok "取不到远端版本：warn 后继续，内核阶段照跑，退出码不受影响"
else
  ng "取不到远端版本：期望 warn + 继续走内核阶段（退出 ${CODE}）"
fi

#-- 9. 下载物 bash -n 不过：不替换 ---------------------------------------
setup
export SB_FAKE_SELF_LATEST=9.9.9
export SB_FAKE_SELF_SCRIPT="$ROOT/broken-singbox.sh"
put_launcher
before=$(sig "$(LAUNCHER)")
sb_launcher
if [ "$(sig "$(LAUNCHER)")" = "$before" ] && [ ! -e "$(LAUNCHER).prev" ] \
   && [ ! -f "$SB_SELF_MARKER" ] && grep -q "语法" "$LOG"; then
  ok "下载物语法不过：不替换，启动器 sha256 不变"
else
  ng "下载物语法不过：期望原文件不变（退出 ${CODE}）"
fi

#-- 10. SB_SELF_UPDATED=1：整段跳过，防 exec 死循环 ----------------------
setup
export SB_FAKE_SELF_LATEST=9.9.9
put_launcher
before=$(sig "$(LAUNCHER)")
SB_SELF_UPDATED=1 sb_launcher
if [ "$(sig "$(LAUNCHER)")" = "$before" ] && [ ! -f "$SB_SELF_MARKER" ] \
   && grep -q "跳过阶段 S" "$LOG"; then
  ok "SB_SELF_UPDATED=1：阶段 S 整段跳过，不会 exec 死循环"
else
  ng "SB_SELF_UPDATED=1：期望整段跳过（退出 ${CODE}）"
fi

#-- 11. $LAUNCHER 不存在（老用户，从未装过）：装进去，且不 re-exec -------
setup
export SB_FAKE_SELF_LATEST=9.9.9
rm -f "$(LAUNCHER)"
sb_repo
if [ -x "$(LAUNCHER)" ] && [ "$(sig "$(LAUNCHER)")" = "$(sig "$ROOT/new-singbox.sh")" ] \
   && [ ! -f "$SB_SELF_MARKER" ] && grep -q "启动器原本不在" "$LOG"; then
  ok "启动器不存在：装进去、说明了这件事，且不 re-exec"
else
  ng "启动器不存在：期望装入且不 exec（存在=$([ -e "$(LAUNCHER)" ] && echo 是 || echo 否)）"
fi

#-- 12. 跑的是仓库副本：更新 $LAUNCHER、warn、不 re-exec -----------------
# 继续用另一份文件跑下去只会让人搞不清到底是谁在执行。
setup
export SB_FAKE_SELF_LATEST=9.9.9
put_launcher
sb_repo
if [ "$(sig "$(LAUNCHER)")" = "$(sig "$ROOT/new-singbox.sh")" ] \
   && [ ! -f "$SB_SELF_MARKER" ] && grep -q "你跑的是" "$LOG"; then
  ok "跑的是仓库副本：更新了 \$LAUNCHER，说明了这件事，不 re-exec"
else
  ng "跑的是仓库副本：期望更新 \$LAUNCHER 且不 exec（退出 ${CODE}）"
fi

#-- 13. 下载物 sha256 对不上：不替换，且**不阻断内核升级** ---------------
# ⚠️ 这条是评审补上的缺口。download() 在「直连下来的文件校验失败」那一档走的是
# die 而不是 return —— 阶段 S 不把它隔离起来的话，整条 update 会退出 1，
# 阶段 0-3 一个字节都跑不到，而那正是「脚本更新不该阻断用户真正要的那件事」
# 禁止的。第 8 条只覆盖「取不到远端版本」，覆盖不到这里。
setup
export SB_FAKE_SELF_LATEST=9.9.9
export SB_FAKE_SELF_BAD_SHA=1
put_launcher
before=$(sig "$(LAUNCHER)")
sb_launcher
if [ "$CODE" = 0 ] && [ "$(sig "$(LAUNCHER)")" = "$before" ] \
   && [ ! -f "$SB_SELF_MARKER" ] \
   && grep -q "sha256 不匹配" "$LOG" && grep -q "已是最新" "$LOG"; then
  ok "下载物 sha256 对不上：不替换，且内核阶段照跑（退出 0）"
else
  ng "下载物 sha256 对不上：期望不替换但内核阶段照跑（退出 ${CODE}，到过阶段 0=$(grep -c "阶段 0/3" "$LOG")）"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
