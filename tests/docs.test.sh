#!/usr/bin/env bash
#
# tests/docs.test.sh —— 文档不许漂移：手册里能机械核对的事实，全部对着源头核对。
#
# 起因（2026-09-11）：README 的仓库结构漏了 3 个测试文件与 5 份 docs，script-usage 的目录
# 漏了 config audit 与 mirror，内置 help 没列 --deep，best-practices 里的「配置全文」还是
# 模板迁移前的旧形状。每一处都是「代码改了、文档没跟」，且没有任何东西会报出来。
#
# 源头：分发表（子命令）、参数解析（config audit 的旗标）、ls（文件清单）、
# singbox-selfcheck.sh（自检项数）、config/config.example.json（配置全文）、各文件自己的标题（目录）。
# docs/ 下「问题 / 决定 / 实现计划」体裁的设计记录写的是当时的判断，不在核对范围——
# 只有 README、script-usage、best-practices 三份手册要时刻准确。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
README=README.md; USAGE=docs/script-usage.md; BP=docs/best-practices.md
MANUALS="$README $USAGE $BP"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/          | /'
  fail=$((fail + 1))
}

echo "验证手册与源头一致"

#-- 1. 子命令：分发表里的每个命令，README 命令表 / script-usage 速查 / 内置 help 都要有 -------
# 分发表形如 `  status)    cmd_status ;;`；help 走 -h，README 表不列它
cmds=$(grep -E '^  [a-z]+\) +cmd_[a-z]+' singbox.sh | sed 's/^  \([a-z]*\)).*/\1/' | grep -v '^help$')
[ -n "$cmds" ] || ng "从分发表解析不出子命令（正则失效）"
help_txt=$(sed -n '/^cmd_help()/,/^EOF$/p' singbox.sh)
usage_quick=$(sed -n '/^## 3\. 命令速查/,/^## 4\./p' "$USAGE")
readme_tbl=$(sed -n '/^## 3\. 管理脚本/,/^## 4\./p' "$README")
miss=""
for c in $cmds; do
  printf '%s\n' "$readme_tbl" | grep -q "\`$c\`" || miss="$miss README:$c"
  printf '%s\n' "$usage_quick" | grep -q "\`$c" || miss="$miss usage:$c"
  printf '%s\n' "$help_txt" | grep -qE "^  $c\b|\| $c\b" || miss="$miss help:$c"
done
if [ -z "$miss" ]; then ok "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ') 个子命令在 README 命令表、script-usage 速查、内置 help 里都有"
else ng "有子命令没写进手册：$miss"; fi

#-- 2. config audit 的旗标：解析器认的每一个，内置 help 与 script-usage 都要列 --------------
flags=$(grep -o 'config audit: 未知参数 \$1（[^）]*）' singbox.sh | grep -o -- '--[a-z]*' | sort -u)
[ -n "$flags" ] || ng "从 config audit 的参数解析里抓不到旗标（die 文案变了？）"
audit_help=$(printf '%s\n' "$help_txt" | grep 'audit \[')
audit_usage=$(sed -n '/^### `config audit`/,/^### /p' "$USAGE")
miss=""
for f in $flags; do
  printf '%s\n' "$audit_help" | grep -q -- "$f" || miss="$miss help:$f"
  printf '%s\n' "$audit_usage" | grep -q -- "$f" || miss="$miss usage:$f"
done
if [ -z "$miss" ]; then ok "config audit 的旗标（$(printf '%s' "$flags" | tr '\n' ' ')）help 与 script-usage 都列全了"
else ng "config audit 有旗标没写进手册：$miss"; fi

#-- 3. README 仓库结构：tests/*.test.sh 与 docs/*.md 一个不多、一个不少 --------------------
tree=$(sed -n '/^## 5\. 仓库结构/,/^## 6\./p' "$README" | sed -n '/^```/,/^```/p')
miss=""; extra=""
for f in tests/*.test.sh docs/*.md; do
  printf '%s\n' "$tree" | grep -q "$(basename "$f")" || miss="$miss $f"
done
for name in $(printf '%s\n' "$tree" | grep -oE '[a-z0-9-]+\.(test\.sh|md)'); do
  [ -f "tests/$name" ] || [ -f "docs/$name" ] || [ -f "$name" ] || extra="$extra $name"
done
if [ -z "$miss$extra" ]; then ok "README 仓库结构与 tests/、docs/ 的实际文件一致"
else ng "README 仓库结构漂移" "漏列：${miss:-无}"$'\n'"多列（文件不存在）：${extra:-无}"; fi

#-- 4. README 的文档索引：docs/ 下每一份都链到 -------------------------------------------
miss=""
for f in docs/*.md; do grep -q "$f" "$README" || miss="$miss $f"; done
if [ -z "$miss" ]; then ok "docs/ 下每份文档 README 都链到了"; else ng "README 没链到：$miss"; fi

#-- 5. 计数：自检项数、测试文件数 ----------------------------------------------------------
n_chk=$(./singbox-selfcheck.sh 2>/dev/null | grep -c ' OK$')
n_tests=$(ls tests/*.test.sh | wc -l | tr -d ' ')
bad=""
for f in $README CLAUDE.md; do
  for n in $(grep -oE '静态自检（[0-9]+ 项）' "$f" | grep -oE '[0-9]+'); do
    [ "$n" = "$n_chk" ] || bad="$bad $f:自检写${n}实际${n_chk}"
  done
done
for n in $(grep -oE '[0-9]+ 个测试文件' CLAUDE.md | grep -oE '[0-9]+'); do
  [ "$n" = "$n_tests" ] || bad="$bad CLAUDE.md:测试文件写${n}实际${n_tests}"
done
grep -qE '[0-9]+ 个测试文件' CLAUDE.md || bad="$bad CLAUDE.md:测试文件数不是阿拉伯数字（核对不了）"
if [ -z "$bad" ]; then ok "自检项数 ${n_chk}、测试文件数 ${n_tests} 与手册一致"; else ng "计数漂移：$bad"; fi

#-- 6. best-practices「配置全文」= config/config.example.json 逐字 -------------------------
blk=$(sed -n '/^## 1\. 配置全文/,/^## 2\./p' "$BP" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')
if [ -n "$blk" ] && diff -q <(printf '%s\n' "$blk") config/config.example.json >/dev/null; then
  ok "best-practices 的配置全文与 config.example.json 逐字一致"
else
  ng "best-practices 的配置全文与 config.example.json 不一致" "$(diff <(printf '%s\n' "$blk") config/config.example.json | head -8)"
fi

#-- 7. 目录与标题一致：## 标题都要在目录里；目录列了三级标题的，### 也要；#### 不管 -------
# 比对前去掉反引号：目录链接文字里不带它
for f in $MANUALS; do
  toc=$(sed -n '/^## 目录/,/^---/p' "$f" | tr -d '`')
  if printf '%s\n' "$toc" | grep -q '^  - \['; then pat='^##(#)? '; else pat='^## '; fi
  heads=$(grep -E "$pat" "$f" | grep -vE '^## (目录|怎么读|免责声明)' | sed -E 's/^#+ //' | tr -d '`')
  miss=""; extra=""
  while IFS= read -r h; do
    printf '%s\n' "$toc" | grep -qF "[$h](" || miss="${miss}「${h}」"
  done <<< "$heads"
  while IFS= read -r t; do
    printf '%s\n' "$heads" | grep -qxF "$t" || extra="${extra}「${t}」"
  done <<< "$(printf '%s\n' "$toc" | grep -oE '\[[^]]+\]\(#' | sed -E 's/^\[//; s/\]\(#$//')"
  if [ -z "$miss$extra" ]; then ok "${f}：目录与标题一致"
  else ng "${f}：目录漂移" "标题不在目录：${miss:-无}"$'\n'"目录里没有的标题：${extra:-无}"; fi
done

#-- 8. 手册里不许有 singbox.sh:行号 —— 行号一改就烂 -----------------------------------------
hits=$(grep -nE 'singbox\.sh:[0-9]+' $MANUALS)
if [ -z "$hits" ]; then ok "手册里没有 singbox.sh:行号 式引用"; else ng "手册里有会烂掉的行号引用" "$hits"; fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
