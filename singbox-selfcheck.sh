#!/usr/bin/env bash
# 脚本自检：跨平台与 set -u 相关的常见隐患
#
# 只用 BSD grep / awk —— 这个脚本自己踩过一次：有 2 项写了 GNU 专有的 grep -P，
# 在 BSD grep 上恒报 invalid option，既抓不到违规也永远不会绿。
# 反过来也踩过：第 7 项的内层正则只匹配恰好 2 空格缩进，于是恒绿、永远不报。
# 每一项都必须在 tests/fixtures/ 里有「会被抓到」和「不该被抓到」两种样本钉住。
F="${1:-singbox.sh}"
fail=0
chk() { printf '  %-46s ' "$1"; shift; if out=$("$@" 2>&1) && [ -z "$out" ]; then echo "OK"; else echo "发现问题:"; echo "$out" | sed 's/^/      /'; fail=1; fi; }

echo "静态自检：$F"
chk "变量紧贴全角字符（bash 3.2 会解析错）" \
    bash -c "LC_ALL=C grep -nE '\\\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' '$F' | grep -v ':[[:space:]]*#' || true"
chk "mktemp 模板 XXXXXX 后带后缀（BSD 不支持）" \
    bash -c "grep -nE 'mktemp[^|]*XXXXXX\\.' '$F' | grep -v ':[[:space:]]*#' || true"
chk "数组在 set -u 下裸展开" \
    bash -c "grep -nE '(^|[^+])\"\\\$\\{[A-Za-z_]+\\[@\\]\\}\"' '$F' | grep -vE 'curl_opts|\\bopts\\b|sources|\\[@\\]\\+' || true"
chk "GNU 专有命令（macOS 无）" \
    bash -c "grep -nE 'sed -i |readlink -f|date -d |head -n -|grep -[a-zA-Z]*P|sort -V|stat -c|base64 -w' '$F' | grep -v ':[[:space:]]*#' || true"
chk "bash 4 专有语法（macOS 只有 3.2）" \
    bash -c "grep -nE 'declare -A|local -n|mapfile|readarray|\\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\^\\^|,,)\\}' '$F' | grep -v ':[[:space:]]*#' || true"
chk "kill -9 / -KILL（会留下残留路由）" \
    bash -c "grep -n 'kill -9\|kill -KILL' '$F' | grep -v '^[0-9]*:[[:space:]]*#' | grep -v '别用\|不要\|不使用\|绝不' || true"
chk "遗留的 launchctl load/unload" \
    bash -c "grep -n 'launchctl load\|launchctl unload' '$F' | grep -v ':[[:space:]]*#' || true"

# shift 2 之前没校验 $2 存在。bash 3.2 的 shift n 在 n > $# 时返回 1 且**不消耗参数**，
# 于是 while [ $# -gt 0 ] 的解析循环永不终止 —— 直接把脚本挂死、CPU 跑满。
chk "shift 2 之前没有 die 护栏" \
    awk 'BEGIN{p=""}
      { line=$0; sub(/^[[:space:]]+/, "", line) }
      line ~ /^#/ { p=$0; next }                      # 注释里写「不要这样写」不算违规
      /shift 2/ { if ($0 !~ /\|\| *die/ && p !~ /\|\| *die/) print NR": "$0 }
      { p=$0 }' "$F"

# grep -c 无匹配时**已经打印了 0** 并返回 1，再 || echo 0 会得到 "0\n0"，
# 后面的 [ -gt ] 会把 `integer expression expected` 打到用户终端 —— 且只在一切正常时发生。
chk "命令替换里 grep -c 叠加 || echo 兜底" \
    bash -c "grep -nE '\\\$\\(grep -[a-zA-Z]*c[a-zA-Z]* .*\\|\\| *echo' '$F' | grep -v ':[[:space:]]*#' || true"

# 同一条 local 里引用前面刚声明的变量。bash 在执行 local 之前就把整行参数展开完了，
# 引用到的是外层作用域（多半是空），而且不报错 —— 功能会静默失效。
chk "同一条 local 语句里引用刚声明的变量" \
    awk '
      /^[[:space:]]*local[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]*local[[:space:]]+/, "", line)
        # 只看这一条 local 自己的参数列表。`local s; s=$(...); local p="${s##*:}"`
        # 是三条独立语句，是**正确**写法，截断到第一个 ; 才不会把它误报出来。
        i = index(line, ";")
        if (i > 0) line = substr(line, 1, i - 1)
        rest = line
        while (match(rest, /[A-Za-z_][A-Za-z0-9_]*=/)) {
          nm = substr(rest, RSTART, RLENGTH - 1)
          pos = index(line, nm "=")
          tail = substr(line, pos + length(nm) + 1)
          if (tail ~ ("\\$\\{?" nm "[^A-Za-z0-9_]") || tail ~ ("\\$\\{?" nm "$")) {
            print NR": "$0; break
          }
          rest = substr(rest, RSTART + RLENGTH)
        }
      }' "$F"

# 函数内嵌函数定义：会捕获外层 local，且 trap 在函数返回后才触发，那时作用域已销毁。
# ⚠️ 内层正则必须是 [[:space:]]+ 而不是恰好两个空格 —— 写死 2 空格就抓不到
# 缩进更深的嵌套定义，这一项会恒绿。
chk "trap 函数内嵌定义（会捕获 local，退出时失效）" \
    bash -c "awk '/^[a-z_]+\\(\\) \\{/{f=1} f&&/^[[:space:]]+[a-z_]+\\(\\) \\{/{print NR\": \"\$0} /^\\}/{f=0}' '$F' || true"
chk "bash 语法" bash -n "$F"
echo
[ "$fail" = 0 ] && echo "全部通过" || { echo "有项目未通过"; exit 1; }
