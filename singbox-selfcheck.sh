#!/usr/bin/env bash
# 脚本自检：跨平台与 set -u 相关的常见隐患
F="${1:-singbox.sh}"
fail=0
chk() { printf '  %-46s ' "$1"; shift; if out=$("$@" 2>&1) && [ -z "$out" ]; then echo "OK"; else echo "发现问题:"; echo "$out" | sed 's/^/      /'; fail=1; fi; }

echo "静态自检：$F"
chk "变量紧贴全角字符（bash 3.2 会解析错）" \
    bash -c "LC_ALL=C grep -nE '\\\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' '$F' | grep -v ':[[:space:]]*#' || true"
chk "mktemp 模板 XXXXXX 后带后缀（BSD 不支持）" \
    bash -c "grep -nE 'mktemp[^|]*XXXXXX\\.' '$F' || true"
chk "数组在 set -u 下裸展开" \
    bash -c "grep -nE '(^|[^+])\"\\\$\\{[A-Za-z_]+\\[@\\]\\}\"' '$F' | grep -vE 'curl_opts|\\bopts\\b|sources|\\[@\\]\\+' || true"
chk "GNU 专有命令（macOS 无）" \
    bash -c "grep -nE 'sed -i |readlink -f|date -d |head -n -|grep -oP' '$F' || true"
chk "kill -9 / -KILL（会留下残留路由）" \
    bash -c "grep -n 'kill -9\|kill -KILL' '$F' | grep -v '^[0-9]*:[[:space:]]*#' | grep -v '别用\|不要\|不使用\|绝不' || true"
chk "遗留的 launchctl load/unload" \
    bash -c "grep -n 'launchctl load\|launchctl unload' '$F' || true"
chk "trap 函数内嵌定义（会捕获 local，退出时失效）" \
    bash -c "awk '/^[a-z_]+\\(\\) \\{/{f=1} f&&/^  [a-z_]+\\(\\) \\{/{print NR\": \"\$0} /^\\}/{f=0}' '$F' || true"
chk "bash 语法" bash -n "$F"
echo
[ "$fail" = 0 ] && echo "全部通过" || { echo "有项目未通过"; exit 1; }
