#!/usr/bin/env bash
#
# tests/docs.test.sh —— 文档不许漂移：手册里能机械核对的事实，全部对着源头核对。
#
# 起因（2026-09-11）：README 的仓库结构漏了 3 个测试文件与 5 份 docs，操作手册的目录
# 漏了 config audit 与 mirror，内置 help 没列 --deep，best-practices 里的「配置全文」还是
# 模板迁移前的旧形状。每一处都是「代码改了、文档没跟」，且没有任何东西会报出来。
#
# 源头：分发表（子命令）、参数解析（config audit 的旗标）、ls（文件清单）、
# singbox-selfcheck.sh（自检项数）、config/config.example.json（配置全文）、各文件自己的标题（目录）。
# 通用规则（引用失联、重复段落、手册骨架、covers）归 sdlc-doc lint；这里只核对本项目特有的事实。
# docs/ 下「问题 / 决定 / 实现计划」体裁的设计记录写的是当时的判断，不在核对范围——
# 要时刻准确的是 README、五份 manual-*.md、best-practices。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
README=README.md; BP=docs/best-practices.md; CFGMAN=docs/manual-config.md
MANUALS="$README docs/manual-*.md $BP"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/          | /'
  fail=$((fail + 1))
}

echo "验证手册与源头一致"

#-- 1. 子命令：分发表里的每个命令，README 命令表 / 内置 help / 某份操作手册都要有 ----------
# 分发表形如 `  status)    cmd_status ;;`；help 走 -h，README 表不列它
cmds=$(grep -E '^  [a-z]+\) +cmd_[a-z]+' singbox.sh | sed 's/^  \([a-z]*\)).*/\1/' | grep -v '^help$')
[ -n "$cmds" ] || ng "从分发表解析不出子命令（正则失效）"
help_txt=$(sed -n '/^cmd_help()/,/^EOF$/p' singbox.sh)
readme_tbl=$(sed -n '/^## 3\. 管理脚本/,/^## 4\./p' "$README")
miss=""
for c in $cmds; do
  printf '%s\n' "$readme_tbl" | grep -q "\`$c\`" || miss="$miss README:$c"
  grep -q "singbox $c\b\|\`$c\`" docs/manual-*.md || miss="$miss manual:$c"
  printf '%s\n' "$help_txt" | grep -qE "^  $c\b|\| $c\b" || miss="$miss help:$c"
done
if [ -z "$miss" ]; then ok "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ') 个子命令在 README 命令表、内置 help、操作手册里都有"
else ng "有子命令没写进手册：$miss"; fi

#-- 2. config audit 的旗标：解析器认的每一个，内置 help 与 manual-config 都要列 ---------------
flags=$(grep -o 'config audit: 未知参数 \$1（[^）]*）' singbox.sh | grep -o -- '--[a-z]*' | sort -u)
[ -n "$flags" ] || ng "从 config audit 的参数解析里抓不到旗标（die 文案变了？）"
audit_help=$(printf '%s\n' "$help_txt" | grep 'audit \[')
audit_usage=$(cat "$CFGMAN")
miss=""
for f in $flags; do
  printf '%s\n' "$audit_help" | grep -q -- "$f" || miss="$miss help:$f"
  printf '%s\n' "$audit_usage" | grep -q -- "$f" || miss="$miss usage:$f"
done
if [ -z "$miss" ]; then ok "config audit 的旗标（$(printf '%s' "$flags" | tr '\n' ' ')）help 与 manual-config 都列全了"
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

#-- 5. 计数：自检项数（测试文件数是 CLAUDE.md 里的 sdlc-doc:n 块，归 sdlc-doc lint 的 D2）----
n_chk=$(./singbox-selfcheck.sh 2>/dev/null | grep -c ' OK$')
bad=""
for f in $README CLAUDE.md; do
  for n in $(grep -oE '静态自检（[0-9]+ 项）' "$f" | grep -oE '[0-9]+'); do
    [ "$n" = "$n_chk" ] || bad="$bad $f:自检写${n}实际${n_chk}"
  done
done
if [ -z "$bad" ]; then ok "自检项数 ${n_chk} 与手册一致"; else ng "计数漂移：$bad"; fi

#-- 6. best-practices「配置全文」= config/config.example.json 逐字 -------------------------
blk=$(sed -n '/^## 1\. 配置全文/,/^## 2\./p' "$BP" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')
if [ -n "$blk" ] && diff -q <(printf '%s\n' "$blk") config/config.example.json >/dev/null; then
  ok "best-practices 的配置全文与 config.example.json 逐字一致"
else
  ng "best-practices 的配置全文与 config.example.json 不一致" "$(diff <(printf '%s\n' "$blk") config/config.example.json | head -8)"
fi

#-- 7. 目录与标题一致：## 标题都要在目录里；目录列了三级标题的，### 也要；#### 不管 -------
# 比对前去掉反引号：目录链接文字里不带它。操作手册 ≤ 120 行没有目录，只查 README 与 best-practices
for f in $README $BP; do
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

#-- 9. findings 文档 ↔ 迁移表：fix 不是 auto 的每个 id 在文档里有且只有一节 `### <id>`，反向每个
#      `### ` 都是表里现存的 id；每节四段小标题齐全；DOC_FINDINGS_URL 指的文件名与 docs/ 实际一致 ----
# id 与 fix 不在同一行，用 awk 在 TABLE 区间里配对；不 source 脚本
FINDINGS=docs/config-audit-findings.md
ids=$(sed -n '/^TABLE = \[/,/^\]/p' singbox.sh | awk '
  /\{"id": "/ { match($0, /"id": "[a-z0-9_]+"/); id = substr($0, RSTART + 7, RLENGTH - 8) }
  /"fix": "/   { match($0, /"fix": "[a-z]+"/); f = substr($0, RSTART + 8, RLENGTH - 9); if (f != "auto") print id }')
n_ids=$(printf '%s\n' "$ids" | grep -c .)
[ "$n_ids" -ge 2 ] || ng "从迁移表抓不到 fix != auto 的 id（awk 配对失效，抓到 ${n_ids} 个）"
if [ ! -f "$FINDINGS" ]; then
  ng "${FINDINGS} 不存在——迁移表里 ${n_ids} 条只报不改的条目没有解读"
else
  bad=""
  for id in $ids; do
    c=$(grep -c "^### ${id}\$" "$FINDINGS")
    [ "$c" = 1 ] || bad="${bad}「${id}：${c} 节」"
  done
  while IFS= read -r h; do
    printf '%s\n' "$ids" | grep -qx "$h" || bad="${bad}「文档多出 ${h}」"
  done <<< "$(grep '^### ' "$FINDINGS" | sed 's/^### //')"
  if [ -z "$bad" ]; then ok "findings 文档与迁移表双向一致（${n_ids} 条）"; else ng "findings 文档与迁移表不一致" "$bad"; fi
  # 每节四段：从 `### id` 到下一个 `### ` / `## ` 之间，四个加粗小标题一个都不能少
  lack=$(awk -v want='问题是什么 模板里的例子 怎么判断 改成什么样' '
    function flush(   i, n, w) { if (sec == "") return; n = split(want, w, " ")
      for (i = 1; i <= n; i++) if (index(body, "**" w[i] "**") == 0) printf "%s 缺「%s」\n", sec, w[i] }
    /^### / { flush(); sec = substr($0, 5); body = ""; next }
    /^## /  { flush(); sec = ""; next }
    { body = body "\n" $0 }
    END { flush() }' "$FINDINGS")
  if [ -z "$lack" ]; then ok "findings 每节四段齐全"; else ng "findings 有节缺段" "$lack"; fi
  url=$(grep -o '^DOC_FINDINGS_URL="[^"]*"' singbox.sh | sed 's/^[^"]*"//; s/"$//')
  if [ -n "$url" ] && [ "docs/$(basename "$url")" = "$FINDINGS" ]; then ok "DOC_FINDINGS_URL 指向 ${FINDINGS}"
  else ng "DOC_FINDINGS_URL 与文档文件名对不上" "常量：${url:-（没抓到）}"$'\n'"文件：${FINDINGS}"; fi
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
