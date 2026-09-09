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
for f in clean.sh bad-fullwidth.sh bad-array.sh bad-gnu.sh bad-shift2.sh \
         bad-localself.sh bad-grepc.sh bad-nested.sh bad-bash4.sh \
         bad-mktemp.sh bad-kill9.sh bad-launchctl.sh bad-syntax.sh \
         bad-cp-launcher.sh good-mv-launcher.sh; do
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


# c4..c12) 其余每一项都必须点名违规那一行。
#         这些项此前一个 fixture 都没有 —— 第 7 项（嵌套函数）当时的正则
#         只匹配恰好 2 空格缩进，恒绿、永远不报，而没有样本能发现这件事。
run "$FIX/bad-shift2.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'shift 2'; then
  ok "bad-shift2.sh：点名了shift 2 没有 die 护栏"
else
  ng "bad-shift2.sh：期望点名shift 2 没有 die 护栏（退出码 ${code}）" "$out"
fi

run "$FIX/bad-localself.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'url='; then
  ok "bad-localself.sh：点名了同一条 local 里引用刚声明的变量"
else
  ng "bad-localself.sh：期望点名同一条 local 里引用刚声明的变量（退出码 ${code}）" "$out"
fi

run "$FIX/bad-grepc.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'grep -ci'; then
  ok "bad-grepc.sh：点名了grep -c 叠加 || echo 兜底"
else
  ng "bad-grepc.sh：期望点名grep -c 叠加 || echo 兜底（退出码 ${code}）" "$out"
fi

run "$FIX/bad-nested.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF '_inner'; then
  ok "bad-nested.sh：点名了6 空格缩进的嵌套函数定义"
else
  ng "bad-nested.sh：期望点名6 空格缩进的嵌套函数定义（退出码 ${code}）" "$out"
fi

run "$FIX/bad-bash4.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'declare -A'; then
  ok "bad-bash4.sh：点名了bash 4 专有的 declare -A"
else
  ng "bad-bash4.sh：期望点名bash 4 专有的 declare -A（退出码 ${code}）" "$out"
fi

run "$FIX/bad-mktemp.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'XXXXXX.json'; then
  ok "bad-mktemp.sh：点名了XXXXXX 后带后缀的 mktemp 模板"
else
  ng "bad-mktemp.sh：期望点名XXXXXX 后带后缀的 mktemp 模板（退出码 ${code}）" "$out"
fi

run "$FIX/bad-kill9.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'kill -9'; then
  ok "bad-kill9.sh：点名了kill -9"
else
  ng "bad-kill9.sh：期望点名kill -9（退出码 ${code}）" "$out"
fi

run "$FIX/bad-launchctl.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'launchctl load'; then
  ok "bad-launchctl.sh：点名了废弃的 launchctl load"
else
  ng "bad-launchctl.sh：期望点名废弃的 launchctl load（退出码 ${code}）" "$out"
fi

run "$FIX/bad-syntax.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'syntax error'; then
  ok "bad-syntax.sh：点名了bash 语法错误"
else
  ng "bad-syntax.sh：期望点名bash 语法错误（退出码 ${code}）" "$out"
fi

# c13) 第 13 项：cp / install 直接覆盖 $LAUNCHER 必须被点名。
#      这一项防的是「脚本更新自己」时覆盖同一个 inode —— 正在跑的进程会读到
#      新文件的字节流、落在错误的偏移上。没有这个样本它就可能恒绿。
run "$FIX/bad-cp-launcher.sh"
if [ "$code" != 0 ] && printf '%s' "$out" | grep -qF 'cp "$tmp" "$LAUNCHER"'; then
  ok "bad-cp-launcher.sh：点名了 cp 直接覆盖 \$LAUNCHER"
else
  ng "bad-cp-launcher.sh：期望点名 cp 直接覆盖 \$LAUNCHER（退出码 ${code}）" "$out"
fi

if printf '%s' "$out" | grep -qF 'install -m 755 "$tmp" "$LAUNCHER"'; then
  ok "bad-cp-launcher.sh：也点名了 install -m 直接覆盖（|| exit 挡不住）"
else
  ng "bad-cp-launcher.sh：期望同时点名 install -m 直接覆盖" "$out"
fi

# c14) 反向：mv 到 $LAUNCHER、以及以 .prev 为目标 / 以 $LAUNCHER 为来源的 cp
#      都是合法写法，一个都不许报 —— 否则第 13 项就是恒红。
run "$FIX/good-mv-launcher.sh"
if [ "$code" = 0 ]; then
  ok "good-mv-launcher.sh：mv 到 \$LAUNCHER 与 .prev 备份都不误报，退出 0"
else
  ng "good-mv-launcher.sh：期望退出 0，实际 ${code}" "$out"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
