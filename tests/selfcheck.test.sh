#!/usr/bin/env bash
#
# tests/selfcheck.test.sh —— 验证 singbox-selfcheck.sh 的检查项真的在检查。
#
# 回归背景：曾有 2 项（「变量紧贴全角字符」「数组在 set -u 下裸展开」）使用了 GNU 专有的
# grep -P。macOS 自带 BSD grep 不支持 -P，两项恒报 "invalid option -- P"——既抓不到违规，
# 也永远不会通过。一条不会绿也不因违规而红的检查是假信号，比没有检查更糟。
#
# 判据不是「退出码非 0」——坏掉的检查器同样退出非 0。判据是：
#   a) 检查器自身不得报工具用法错误
#   b) 干净样本必须退出 0
#   c) 违规样本的输出里必须点名那一行违规内容
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SELFCHECK=./singbox-selfcheck.sh
FIX=tests/fixtures
pass=0
fail=0
out=''
code=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  if [ $# -gt 1 ]; then printf '%s\n' "$2" | sed 's/^/          | /'; fi
  fail=$((fail + 1))
}
run() { out=$("$SELFCHECK" "$1" 2>&1); code=$?; }

echo "验证 $SELFCHECK 的检查项是否真的在检查"

# a) 检查器自身不得报工具用法错误
for f in clean.sh bad-fullwidth.sh bad-array.sh bad-gnu.sh; do
  run "$FIX/$f"
  if printf '%s' "$out" | grep -qE 'invalid option|illegal option|usage: grep'; then
    ng "${f}：检查器自身报了工具用法错误" "$out"
  else
    ok "${f}：检查器没有自身报错"
  fi
done

# b) 干净样本必须全绿
run "$FIX/clean.sh"
if [ "$code" = 0 ]; then
  ok "clean.sh：退出 0"
else
  ng "clean.sh：期望退出 0，实际 $code" "$out"
fi

# c1) 全角紧贴必须被点名
run "$FIX/bad-fullwidth.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -q 'name中文'; then
  ok "bad-fullwidth.sh：点名了 \$name中文"
else
  ng "bad-fullwidth.sh：期望点名 \$name中文（退出码 ${code}）" "$out"
fi

# c2) 数组裸展开必须被点名
run "$FIX/bad-array.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -q 'args\[@\]'; then
  ok "bad-array.sh：点名了裸 \"\${args[@]}\""
else
  ng "bad-array.sh：期望点名裸 \"\${args[@]}\"（退出码 ${code}）" "$out"
fi

# c3) GNU 专有的 grep -P 必须被点名。历史上这条规则只列了 grep -oP，
#     于是 singbox-selfcheck.sh 自己用的 grep -nP 从守卫旁边走了过去。
run "$FIX/bad-gnu.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -q 'grep -nP'; then
  ok "bad-gnu.sh：点名了 grep -nP"
else
  ng "bad-gnu.sh：期望点名 grep -nP（退出码 ${code}）" "$out"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
