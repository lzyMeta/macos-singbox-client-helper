#!/usr/bin/env bash
#
# tests/config-export.test.sh —— `config export <path> [--force]` 的断言（docs/config-export.md AC1–AC6）。
#
# 导出物带订阅地址与节点凭据，所以这里盯三件事：**不覆盖、不敞开、不骗人**——
# 目标存在要拒绝、mode 必须是 0600、磁盘比进程新要 warn 一句。
#
# 全程离线、不要 sudo、不碰真实系统：--prefix 指到临时目录，tests/fixtures/bin 前置到 PATH
# 拿假 pgrep（SB_FAKE_STATE/running），本文件再自造一个假 ps（SB_FAKE_STATE/etime）
# 放在它前面——真 ps 没法让「进程已跑 1 小时」这件事可复现。
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

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  export SB_FAKE_STATE="$ROOT/state"; mkdir -p "$SB_FAKE_STATE"
  export XDG_CONFIG_HOME="$ROOT/xdg";  mkdir -p "$XDG_CONFIG_HOME"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box" "$ROOT/stub"
  : > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"
  echo 0 > "$SB_FAKE_STATE/running"        # 默认没进程在跑

  # 假 ps：只接管 `ps -o etime= -p <pid>`，其余透传给真 ps。
  cat > "$ROOT/stub/ps" <<'EOF'
#!/usr/bin/env bash
S="${SB_FAKE_STATE:?}"
case "$*" in
  *etime*) [ -f "$S/etime" ] && { cat "$S/etime"; exit 0; } ;;
esac
exec /bin/ps "$@"
EOF
  chmod 755 "$ROOT/stub/ps"

  CFG="$ROOT/prefix/etc/sing-box/config.json"
  printf '{"log":{"level":"info"},"outbounds":[{"type":"shadowsocks","password":"s3cret"}]}\n' > "$CFG"
  chmod 644 "$CFG"
}
teardown() { [ -n "$ROOT" ] && rm -rf "$ROOT"; ROOT=""; }
trap teardown EXIT

sb() { PATH="$ROOT/stub:$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" "$@" >"$LOG" 2>&1; CODE=$?; }
sha() { shasum "$1" | awk '{print $1}'; }

echo "== config export =="

#-- AC1 逐字节全等 ----------------------------------------------------------------
setup
OUT="$ROOT/out.json"
sb config export "$OUT"
if [ "$CODE" = 0 ] && cmp -s "$CFG" "$OUT"; then ok "AC1 导出退出 0，与源 cmp 全等"
else ng "AC1 期望退出 0 且 cmp 全等（实际退出 ${CODE}）"; fi

#-- AC4 mode 0600、owner 是调用者 -------------------------------------------------
mode=$(stat -f %Lp "$OUT" 2>/dev/null); uid=$(stat -f %u "$OUT" 2>/dev/null)
if [ "$mode" = 600 ] && [ "$uid" = "$(id -u)" ]; then ok "AC4 导出物 mode 0600、owner 是调用者"
else ng "AC4 期望 600 / uid $(id -u)（实际 ${mode:-?} / ${uid:-?}）"; fi

#-- AC2 目标已存在：无 --force 拒绝且不动，带 --force 覆盖 --------------------------
setup
OUT="$ROOT/old.json"
printf 'OLD CONTENT\n' > "$OUT"; before=$(sha "$OUT")
sb config export "$OUT"
if [ "$CODE" != 0 ] && grep -q '已存在' "$LOG" && [ "$(sha "$OUT")" = "$before" ]; then
  ok "AC2 目标已存在无 --force：退出非 0、提示已存在、目标逐字节不变"
else ng "AC2 期望拒绝且目标不变（退出 ${CODE}，sha 变=$([ "$(sha "$OUT")" != "$before" ] && echo yes || echo no)）"; fi
sb config export "$OUT" --force
if [ "$CODE" = 0 ] && cmp -s "$CFG" "$OUT"; then ok "AC2 带 --force：覆盖成功且与源全等"
else ng "AC2 期望 --force 覆盖成功（退出 ${CODE}）"; fi

#-- AC3 坏路径三种：不给、是目录、父目录不存在 ---------------------------------------
setup
sb config export
if [ "$CODE" != 0 ] && grep -q '用法\|需要' "$LOG"; then ok "AC3 不给路径：退出非 0 且带用法"
else ng "AC3 不给路径期望 die 带用法（退出 ${CODE}）"; fi
mkdir -p "$ROOT/adir"
sb config export "$ROOT/adir"
if [ "$CODE" != 0 ] && grep -q '目录' "$LOG" && [ -z "$(ls -A "$ROOT/adir")" ]; then ok "AC3 路径是目录：拒绝且目录里不出现文件"
else ng "AC3 路径是目录期望拒绝（退出 ${CODE}）"; fi
sb config export "$ROOT/nope/out.json"
if [ "$CODE" != 0 ] && grep -q '父目录' "$LOG" && [ ! -e "$ROOT/nope" ]; then ok "AC3 父目录不存在：拒绝且不创建"
else ng "AC3 父目录不存在期望拒绝（退出 ${CODE}）"; fi
sb config export "$ROOT/x.json" --bogus
if [ "$CODE" != 0 ] && grep -q '未知参数' "$LOG" && [ ! -e "$ROOT/x.json" ]; then ok "AC3 未知旗标：拒绝且不写文件"
else ng "AC3 未知旗标期望拒绝（退出 ${CODE}）"; fi

#-- AC5 -n 只打印计划 --------------------------------------------------------------
setup
OUT="$ROOT/dry.json"
sb -n config export "$OUT"
if [ "$CODE" = 0 ] && grep -q 'dry-run' "$LOG" && [ ! -e "$OUT" ]; then ok "AC5 -n：退出 0、打印计划、目标不出现"
else ng "AC5 -n 期望退出 0 且目标不出现（退出 ${CODE}，存在=$([ -e "$OUT" ] && echo yes || echo no)）"; fi

#-- AC6 进程陈旧性警告 -------------------------------------------------------------
# 进程跑了 1 小时、配置 mtime 是现在 → 磁盘比进程新，warn。
setup
echo 1 > "$SB_FAKE_STATE/running"; echo '01:00:00' > "$SB_FAKE_STATE/etime"
touch "$CFG"
sb config export "$ROOT/a.json"
if [ "$CODE" = 0 ] && grep -q '比运行中的进程新' "$LOG" && cmp -s "$CFG" "$ROOT/a.json"; then
  ok "AC6 进程比文件旧：warn 一句，退出仍为 0，照常导出"
else ng "AC6 期望 warn 且退出 0（退出 ${CODE}）"; fi
# 进程刚起 1 秒、配置 mtime 是 1 小时前 → 进程比文件新，不警告。
echo '00:01' > "$SB_FAKE_STATE/etime"
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$CFG"
sb config export "$ROOT/b.json"
if [ "$CODE" = 0 ] && ! grep -q '比运行中的进程新' "$LOG"; then ok "AC6 进程比文件新：不警告"
else ng "AC6 进程比文件新不该警告（退出 ${CODE}）"; fi
# 没进程在跑 → 不警告。
echo 0 > "$SB_FAKE_STATE/running"; echo '01:00:00' > "$SB_FAKE_STATE/etime"; touch "$CFG"
sb config export "$ROOT/c.json"
if [ "$CODE" = 0 ] && ! grep -q '比运行中的进程新' "$LOG"; then ok "AC6 无进程：不警告"
else ng "AC6 无进程不该警告（退出 ${CODE}）"; fi
# 跑了 1 天 2 小时（dd-hh:mm:ss 形态）也要解析对：磁盘现在 → warn。
echo 1 > "$SB_FAKE_STATE/running"; echo '1-02:00:00' > "$SB_FAKE_STATE/etime"; touch "$CFG"
sb config export "$ROOT/d.json"
if [ "$CODE" = 0 ] && grep -q '比运行中的进程新' "$LOG"; then ok "AC6 etime 带天数（dd-hh:mm:ss）也能判出陈旧"
else ng "AC6 dd-hh:mm:ss 形态期望 warn（退出 ${CODE}）"; fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
