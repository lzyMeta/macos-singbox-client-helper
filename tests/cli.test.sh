#!/usr/bin/env bash
#
# tests/cli.test.sh —— 顶层参数解析与分发的断言。
#
# 这一层以前一条测试都没有，而它恰恰藏着最严重的一个缺陷：
# bash 3.2 的 `shift n` 在 n > $# 时**返回 1 且不消耗任何参数**，
# 于是 `while [ $# -gt 0 ]` 的解析循环永不终止——`singbox.sh status --version`
# 会把 CPU 跑满、ARGS 数组无限增长，直到用户自己 Ctrl-C。
#
# 所以这里每条用例都必须带**超时**：判据不只是「退出码对」，
# 更是「它到底有没有在有限时间内退出」。没有超时的话，回归会表现为测试挂死，
# 而不是测试变红。
#
# 前 6 组用例全程不碰系统：要么在参数解析阶段就 die，要么在 dispatch 前的门卫处 die，
# 两者都发生在任何 launchctl / sudo 之前。
#
# ⚠️ 第 7 组（服务控制类的 --dry-run）不一样。它依赖的正是「被测脚本认 $DRY」这件事，
# 而 $PLIST 与 $LOGFILE 是写死的绝对路径，--prefix 改不到。所以：
#   拿一个**没有 dry-run 护栏的旧版本**跑 SB_UNDER_TEST，且当前 shell 有 sudo 票据时，
#   `-n stop` 会真的 launchctl bootout 掉这台机器上的 sing-box。
# 对着仓库里的 singbox.sh 跑没有这个问题（它有护栏）；只有在做「确认这些用例真会红」
# 这类对照实验时才要留意，先 sudo -k 清掉票据再跑。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# 被测脚本可覆盖，这样能拿旧版本跑一遍确认这些用例真的会红，
# 而不必把工作区里的 singbox.sh 换来换去（换到一半失败就留下一个坏文件）。
SB="${SB_UNDER_TEST:-./singbox.sh}"
pass=0; fail=0
OUT=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  fail=$((fail + 1))
}

# run <秒> <参数…> —— 跑 singbox.sh，超时就杀掉并把 CODE 置成 124（同 GNU timeout 的约定）。
# macOS 自带没有 timeout(1)，这里用后台进程 + 轮询自己实现。
run() {
  local limit="$1"; shift
  local tmp; tmp=$(mktemp)
  "$SB" "$@" >"$tmp" 2>&1 &
  local pid=$! i=0 done=0
  while [ "$i" -lt $((limit * 10)) ]; do
    kill -0 "$pid" 2>/dev/null || { done=1; break; }
    /bin/sleep 0.1
    i=$((i + 1))
  done
  if [ "$done" = 1 ]; then
    wait "$pid"; CODE=$?
  else
    # ⚠️ 必须升级到 KILL。singbox.sh 自己装了 `trap cleanup EXIT INT TERM`，
    # 而那个 handler 不 exit —— 陷在解析死循环里时，TERM 被 trap 吸收、
    # 处理完继续转，光发 TERM 杀不掉，测试自己会挂死。
    kill -TERM "$pid" 2>/dev/null
    local j=0
    while [ "$j" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.1; j=$((j + 1)); done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    CODE=124
  fi
  OUT=$(cat "$tmp"); rm -f "$tmp"
}

echo "验证顶层参数解析与分发"

#-- 1. 缺值的 --version 跟在命令后：必须干净 die，不能死循环 --------------
run 5 status --version
if [ "$CODE" = 1 ] && printf '%s' "$OUT" | grep -q -- '--version 需要参数'; then
  ok "status --version（缺值）：立即 die 报「--version 需要参数」"
elif [ "$CODE" = 124 ]; then
  ng "status --version（缺值）：**死循环了**，5 秒内没退出" "$OUT"
else
  ng "status --version（缺值）：期望退 1 并报缺参数（实际 ${CODE}）" "$OUT"
fi

#-- 2. install 的三个带值参数缺值时同样不能死循环 -------------------------
for opt in --config --version --arch; do
  run 5 install "$opt"
  if [ "$CODE" = 1 ] && printf '%s' "$OUT" | grep -q -- "$opt 需要参数"; then
    ok "install ${opt}（缺值）：立即 die 报「${opt} 需要参数」"
  elif [ "$CODE" = 124 ]; then
    ng "install ${opt}（缺值）：**死循环了**，5 秒内没退出" "$OUT"
  else
    ng "install ${opt}（缺值）：期望退 1 并报缺参数（实际 ${CODE}）" "$OUT"
  fi
done

#-- 3. --version 单独用仍要打印版本号 -------------------------------------
# 上面那道护栏不能把这条既有行为改坏：CMD 为空时 --version 是「打印脚本版本」。
run 5 --version
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -q 'singbox.sh v'; then
  ok "单独的 --version：打印版本号并退 0"
else
  ng "单独的 --version：期望退 0 并打印版本（实际 ${CODE}）" "$OUT"
fi

#-- 4. 不收参数的命令收到多余参数：必须报错而不是默默跑完 ------------------
# 改动之前 dispatch 里这批命令写成 `cmd_xxx ;;`，不转发 ARGS，
# 于是 `singbox.sh status thisIsBogus` 一声不响地正常跑完并退 0。
run 5 status thisIsBogusExtraArg
if [ "$CODE" = 1 ] && printf '%s' "$OUT" | grep -q '不接受参数'; then
  ok "status 带多余参数：报「不接受参数」并退 1"
else
  ng "status 带多余参数：期望退 1 并报不接受参数（实际 ${CODE}）" "$OUT"
fi

run 5 verify --alsoBogus
if [ "$CODE" = 1 ] && printf '%s' "$OUT" | grep -q '不接受参数'; then
  ok "verify 带多余的 --flag：报「不接受参数」并退 1"
else
  ng "verify 带多余的 --flag：期望退 1 并报不接受参数（实际 ${CODE}）" "$OUT"
fi

#-- 5. 收参数的命令不能被门卫误伤 -----------------------------------------
# logs 是收参数的（logs [n|-f]）。它不该出现在门卫名单里。
run 5 logs 5
if printf '%s' "$OUT" | grep -q '不接受参数'; then
  ng "logs 5：被门卫误伤了（logs 是收参数的）" "$OUT"
else
  ok "logs 5：没有被门卫误伤"
fi

#-- 6. 未知命令仍要报错 ---------------------------------------------------
run 5 nosuchcommand
if [ "$CODE" = 1 ] && printf '%s' "$OUT" | grep -q '未知命令'; then
  ok "未知命令：报「未知命令」并退 1"
else
  ng "未知命令：期望退 1 并报未知命令（实际 ${CODE}）" "$OUT"
fi

#-- 7. --dry-run 在服务控制类命令上必须真的只打印 -------------------------
# 改动之前这几个命令通篇不看 $DRY：`-n stop` 会真的 launchctl bootout，
# `-n debug` 会真的把内核跑到前台。判据是「打了 [dry-run] 且干净退出」——
# 这些用例不能真的动系统，所以 --prefix 指向临时目录、只放一个空壳 $BIN 和 $CFG。
PREFIX=$(mktemp -d)
mkdir -p "$PREFIX/bin" "$PREFIX/etc/sing-box"
: > "$PREFIX/bin/sing-box"; chmod 755 "$PREFIX/bin/sing-box"
echo '{}' > "$PREFIX/etc/sing-box/config.json"

for c in stop restart debug; do
  run 10 -n --prefix "$PREFIX" "$c"
  if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -q 'dry-run'; then
    ok "-n ${c}：退出 0 且只打印 [dry-run]"
  elif [ "$CODE" = 124 ]; then
    ng "-n ${c}：10 秒内没退出（多半是真的去动系统了）" "$OUT"
  else
    ng "-n ${c}：期望退 0 且出现 [dry-run]（实际 ${CODE}）" "$OUT"
  fi
done

#-- 8. -n mirror set 不该写偏好文件 --------------------------------------
XDG=$(mktemp -d)
run 10 -n --prefix "$PREFIX" mirror set https://example.invalid
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -q 'dry-run' \
   && [ ! -f "$XDG/singbox/prefs" ]; then
  ok "-n mirror set：退出 0 且没写 prefs"
else
  ng "-n mirror set：期望退 0、只打印、不写 prefs（实际 ${CODE}）" "$OUT"
fi
rm -rf "$PREFIX" "$XDG"

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
