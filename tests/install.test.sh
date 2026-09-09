#!/usr/bin/env bash
#
# tests/install.test.sh —— cmd_install 把脚本自己装成 $PREFIX/bin/singbox 这一步。
#
# 全程离线、不要 sudo、不碰真实系统：tests/fixtures/bin 前置到 PATH，
# --prefix 指到临时目录，假内核由 tests/fixtures/fake-sing-box 实例化而来。
#
# ⚠️ 这里**故意不跑完整的 install**。第 7/8 步会 `sudo cp` 一份 plist 到
# /Library/LaunchDaemons/sing-box.plist —— 那个路径写死在 $PLIST 里，**不跟随
# --prefix**，跑到那一步就会动真实系统的 LaunchDaemon。所以用
# SB_FAKE_CHECK_FAIL="live:<版本>" 让第 5/8 步静态校验失败而中止：
# 启动器那一步（2/8）紧跟在内核（1/8）之后，那时早就执行完了，
# 断言对象（存在 / 0755 / 逐字节相同 / .prev 的内容）一条不少。
# 要真正跑完 install 得先让 $PLIST 可覆盖，那是另一个改动。
#
# 判据始终是**两面**：新的就位，且旧的那份有退路（.prev）。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB=./singbox.sh
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"
VER=1.13.19

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
sig()  { [ -f "$1" ] && shasum "$1" | awk '{print $1}'; }
mode() { [ -f "$1" ] && stat -f '%Lp' "$1"; }

LAUNCHER() { printf '%s' "$ROOT/prefix/bin/singbox"; }

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state";  mkdir -p "$SB_FAKE_STATE"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"

  export SB_FAKE_LIVE_BIN="$ROOT/prefix/bin/sing-box"
  export SB_FAKE_LATEST="$VER"
  # 第 5/8 步静态校验失败 —— 这是本测试的断点，见文件头。
  export SB_FAKE_CHECK_FAIL="live:$VER"

  # 装机用的源配置。绝对路径的 cache_file，免得触发那道「改成绝对路径？」的询问。
  cat > "$ROOT/config.json" <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 21888 }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "experimental": {
    "cache_file": { "enabled": true, "path": "/usr/local/etc/sing-box/cache.db" }
  }
}
JSON

  # 与 GitHub 上同构的 tar.gz：sing-box-<版本>-darwin-<arch>/sing-box
  local arch; arch=$([ "$(uname -m)" = arm64 ] && echo arm64 || echo amd64)
  local d="$ROOT/pkg/sing-box-${VER}-darwin-${arch}"
  mkdir -p "$d"; mk_bin "$d/sing-box" "$VER"
  ( cd "$ROOT/pkg" && tar czf "$ROOT/kernel.tar.gz" "sing-box-${VER}-darwin-${arch}" )
  export SB_FAKE_TARBALL="$ROOT/kernel.tar.gz"

  unset SB_FAKE_BAD_SHA SB_FAKE_NO_DIGEST SB_FAKE_PROBE_FAIL
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf /tmp/.singbox-sh.lock 2>/dev/null
  ROOT=""
}
trap teardown EXIT

sb() {
  PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" \
    --config "$ROOT/config.json" >"$LOG" 2>&1
  CODE=$?
}

echo "验证 install 把脚本自己装成 \$PREFIX/bin/singbox"

#-- 1. 干净安装：就位、可执行、与源脚本逐字节相同 -----------------------
setup
sb install
if [ -x "$(LAUNCHER)" ] && [ "$(sig "$(LAUNCHER)")" = "$(sig "$SB")" ] \
   && [ "$(mode "$(LAUNCHER)")" = 755 ]; then
  ok "干净安装：\$PREFIX/bin/singbox 就位，0755，与源脚本逐字节相同"
else
  ng "干净安装：期望 0755 且内容同源（存在=$([ -e "$(LAUNCHER)" ] && echo 是 || echo 否) 权限=$(mode "$(LAUNCHER)")）"
fi

#-- 2. 目标已有**不同**内容：旧的进 .prev，新的就位 ---------------------
setup
printf '#!/usr/bin/env bash\necho 老版本\n' > "$(LAUNCHER)"
chmod 755 "$(LAUNCHER)"
oldsig=$(sig "$(LAUNCHER)")
sb install
if [ "$(sig "$(LAUNCHER)")" = "$(sig "$SB")" ] \
   && [ "$(sig "$(LAUNCHER).prev")" = "$oldsig" ]; then
  ok "已有旧版本：新的就位，旧的原样进了 .prev"
else
  ng "已有旧版本：期望旧内容出现在 .prev（.prev 存在=$([ -e "$(LAUNCHER).prev" ] && echo 是 || echo 否)）"
fi

#-- 3. 目标已有**相同**内容：仍然就位，且不报错 -------------------------
setup
cp "$SB" "$(LAUNCHER)"; chmod 755 "$(LAUNCHER)"
sb install
# ⚠️ 判据不能是「日志里没有 ✗」—— 本测试的断点就是第 5/8 步校验失败，
# 那一个 ✗ 总是在的。只能问启动器自己那一步有没有报错。
if [ "$(sig "$(LAUNCHER)")" = "$(sig "$SB")" ] \
   && grep -qF "已安装到 $(LAUNCHER)" "$LOG" \
   && ! grep '✗' "$LOG" | grep -qF "$(LAUNCHER)"; then
  ok "内容相同：仍然就位，启动器这一步没报错"
else
  ng "内容相同：期望就位且启动器那一步无 ✗" "$(grep '✗' "$LOG" | head -3)"
fi

#-- 4. dry-run：不落盘，但要说出打算做什么 ------------------------------
setup
sb -n install
# ⚠️ 别拿 '[dry-run].*singbox' 当判据：$PREFS_DIR 就是 <XDG>/singbox，
# dns-backup 那行会把它匹配上，于是这条断言在启动器根本没实现时也是绿的。
# 判据必须点名启动器自己的路径。
if [ ! -e "$(LAUNCHER)" ] \
   && grep -F '[dry-run]' "$LOG" | grep -qF "$(LAUNCHER)"; then
  ok "-n install：没有创建启动器，但打印了 [dry-run] 那一行"
else
  ng "-n install：期望不落盘且有 [dry-run] 行（存在=$([ -e "$(LAUNCHER)" ] && echo 是 || echo 否)）" \
     "$(grep -F '[dry-run]' "$LOG")"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
