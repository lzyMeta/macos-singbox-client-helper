#!/usr/bin/env bash
#
# tests/template.test.sh —— config/config.example.json 必须跟得上 live 配置。
#
# 起因（2026-09-11）：config audit --apply 把 live 的 21 条 download_detour 迁成了内联
# http_client，用户又手工 `sing-box format` 过一遍（默认值字段被剥掉、单元素数组变标量、
# 键序按内核结构体排、7d 写成 168h0m0s），而模板一直停在初始提交的形状——对模板跑
# config audit 会报 21 处「将来会坏」。模板是给新装机 cp 走的那份，它落后就等于每台
# 新机器都从一份废弃配置起步。
#
# 两道断言：
#   1. 离线、每台机器都跑：对模板本身跑 config audit，不许有「将来会坏 / 已坏」
#      （提示档允许——那是语义定性，不是合法性）。
#   2. 有 live 配置就比、没有就跳过：模板与 live 逐键比对——键路径、键顺序、非占位符的值
#      三样全等；占位符（值以 YOUR_ 开头）只要求 live 那边已填。$schema 是模板专属
#      （编辑器补全用，见 docs/best-practices.md），是唯一允许的差异。
#      ⚠️ 这一道**只打印路径、不打印任何值**：live 里是真凭据。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"
FIX="$PWD/tests/fixtures"
TPL="$PWD/config/config.example.json"
# 要比对的 live 配置。设成空串即跳过第 2 道（CI / 别的机器）。
LIVE="${SB_TEMPLATE_LIVE-/usr/local/etc/sing-box/config.json}"

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  fail=$((fail + 1))
}

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"
  sed "s/__VERSION__/1.14.0/" "$FAKE" > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"
  cp "$FIX/good-http-client.json" "$ROOT/prefix/etc/sing-box/config.json"
  export XDG_CONFIG_HOME="$ROOT/xdg"; mkdir -p "$XDG_CONFIG_HOME"
  export SB_FAKE_STATE="$ROOT/state"; mkdir -p "$SB_FAKE_STATE"
  export SB_FAKE_SCHEMA="$FIX/schema-min.json"
}
teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf "${SB_LOCKDIR:-/tmp/.singbox-sh.lock}" 2>/dev/null
  ROOT=""
}
trap teardown EXIT

echo "验证 config/config.example.json 跟得上 live 配置"

#-- 1. 模板本身过 config audit ------------------------------------------------
setup
PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y config audit --config "$TPL" >"$LOG" 2>&1
CODE=$?
if grep -q '配置审查：' "$LOG"; then
  ok "发现层跑起来了"
else
  ng "发现层没跑起来（下面的断言不可信）" "$(tail -5 "$LOG")"
fi
if [ "$CODE" = 0 ]; then
  ok "模板通过 config audit（退 0，只允许提示档）"
else
  ng "模板没通过 config audit：退 $CODE" "$(grep -E '将来会坏|已坏' "$LOG" | head -5)"
fi
# 三条 auto 规则的旧键一个都不许出现——它们是 --apply 会改掉的东西，模板里留着
# 就是让每台新机器装完第一件事是跑 --apply
for k in download_detour independent_cache store_rdrc; do
  if grep -q "\"$k\"" "$TPL"; then
    ng "模板里还有 ${k}（--apply 会改的旧键）"
  else
    ok "模板里没有 ${k}"
  fi
done

#-- 2. 与 live 逐键比对（只打印路径，不打印值）--------------------------------
if [ -z "$LIVE" ]; then
  echo "  SKIP  未指定 live 配置（SB_TEMPLATE_LIVE 为空），跳过逐键比对"
elif [ ! -r "$LIVE" ]; then
  echo "  SKIP  读不到 $LIVE，跳过逐键比对"
else
  out=$(python3 - "$TPL" "$LIVE" <<'PY'
import json, sys
tpl = json.load(open(sys.argv[1])); live = json.load(open(sys.argv[2]))
bad = []
def walk(a, b, p):
    if isinstance(a, str) and a.startswith("YOUR_"):
        if not (isinstance(b, str) and b and not b.startswith("YOUR_")):
            bad.append(f"占位符未填  {p}")
        return
    if type(a) is not type(b):
        bad.append(f"类型不同    {p}  模板 {type(a).__name__} / live {type(b).__name__}"); return
    if isinstance(a, dict):
        ka = [k for k in a if not (p == "" and k == "$schema")]; kb = list(b)
        if ka != kb:
            only_a = [k for k in ka if k not in kb]; only_b = [k for k in kb if k not in ka]
            if only_a or only_b:
                bad.append(f"键集不同    {p or '<root>'}  模板独有 {only_a} / live 独有 {only_b}")
            else:
                bad.append(f"键序不同    {p or '<root>'}  模板 {ka} / live {kb}")
        for k in ka:
            if k in b: walk(a[k], b[k], f"{p}.{k}" if p else k)
    elif isinstance(a, list):
        if len(a) != len(b):
            bad.append(f"长度不同    {p}  模板 {len(a)} / live {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)): walk(x, y, f"{p}[{i}]")
    elif a != b:
        bad.append(f"值不同      {p}")
walk(tpl, live, "")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)
  if [ $? = 0 ]; then
    ok "模板与 live 逐键全等（占位符除外）"
  else
    n=$(printf '%s\n' "$out" | grep -c .)
    ng "模板与 live 有 $n 处不一致（live 变了就同步模板：值照抄、7 个凭据换回 YOUR_ 占位符）" "$(printf '%s\n' "$out" | head -40)"
  fi
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
