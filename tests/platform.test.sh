#!/usr/bin/env bash
#
# tests/platform.test.sh —— 平台与 CPU 架构的识别。
#
# 复现的 bug：detect_arch 只看 `uname -m`。而 uname -m 报的是**当前进程**的架构，
# 不是硬件的——Apple Silicon 上被 Rosetta 2 翻译的进程里它会说 x86_64。
# 于是从一个被翻译的 shell 里跑 install（Rosetta 方式打开的终端、x86_64 的
# Homebrew bash、`arch -x86_64 bash`……都算），会在 ARM 机器上装 Intel 内核：
#   - 一个常驻的网络路径守护进程被塞进翻译层
#   - install --arch arm64 反过来警告「与本机 amd64 不符」
#   - cmd_update 也走同一个 detect_arch，会把这个错误一直续下去
#
# 真机实测的判据（在 Intel i9 上跑出来的）：
#   真 Intel        hw.optional.arm64 与 sysctl.proc_translated 都不存在，sysctl 退出 1
#   Apple Silicon   hw.optional.arm64=1；sysctl.proc_translated 存在，原生时为 0
#   Rosetta 翻译中  同上，但 sysctl.proc_translated=1
#
# 观测点：install 在动 sudo 与下载之前就会打印「架构：<uname -m> → darwin-<arch>」，
# 随后在配置文件检查处 die。所以给一个不存在的 --config 就能只测架构判定这一段，
# 全程不联网、不提权、不碰真实系统。
#
# Windows 不在这份测试的「适配」范围里，而且那不是 bug：launchctl / networksetup /
# plutil / scutil / LaunchDaemon plist 全是 macOS 专有，支持 Windows 是另写一个程序。
# 这里只要求它**拒绝得清楚**——点名当前系统、说明为什么。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"
STUB="$PWD/tests/fixtures/bin-platform"
pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && sed 's/^/          > /' "$LOG"
  fail=$((fail + 1))
}

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  mkdir -p "$ROOT/prefix"
  unset SB_FAKE_UNAME_S SB_FAKE_UNAME_M SB_FAKE_ARM64 SB_FAKE_TRANSLATED
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf "${SB_LOCKDIR:-/tmp/.singbox-sh.lock}" 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# 只把 uname / sysctl 两个桩前置到 PATH，其余命令走真的。
# --config 指向一个不存在的路径：架构那几行打完就 die，不会走到 need_root 与下载。
sb() {
  PATH="$STUB:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" >"$LOG" 2>&1
  CODE=$?
}
inlog() { grep -q "$1" "$LOG"; }

install_probe() { sb install --config "$ROOT/nope.json"; }

echo "验证平台与 CPU 架构识别"

#-- 1. 真 Intel：两个 sysctl 键都不存在 -----------------------------------
setup
SB_FAKE_UNAME_M=x86_64 install_probe
if inlog "darwin-amd64"; then
  ok "真 Intel：选 darwin-amd64"
else
  ng "真 Intel：期望 darwin-amd64（退出 ${CODE}）"
fi

#-- 2. Apple Silicon 原生 -------------------------------------------------
setup
SB_FAKE_UNAME_M=arm64 SB_FAKE_ARM64=1 SB_FAKE_TRANSLATED=0 install_probe
if inlog "darwin-arm64"; then
  ok "Apple Silicon 原生：选 darwin-arm64"
else
  ng "Apple Silicon 原生：期望 darwin-arm64（退出 ${CODE}）"
fi

#-- 3. Apple Silicon + Rosetta：uname -m 说谎 -----------------------------
# 这是这个 bug 的核心。硬件是 arm64，但进程被翻译了，uname -m 报 x86_64。
setup
SB_FAKE_UNAME_M=x86_64 SB_FAKE_ARM64=1 SB_FAKE_TRANSLATED=1 install_probe
if inlog "darwin-arm64"; then
  ok "Apple Silicon + Rosetta：仍然选 darwin-arm64（不被 uname -m 骗）"
else
  ng "Apple Silicon + Rosetta：期望 darwin-arm64，被 uname -m 骗成了 amd64（退出 ${CODE}）"
fi

#-- 4. Rosetta 之下要明说，否则用户无从判断 -------------------------------
setup
SB_FAKE_UNAME_M=x86_64 SB_FAKE_ARM64=1 SB_FAKE_TRANSLATED=1 install_probe
if inlog "Rosetta"; then
  ok "Apple Silicon + Rosetta：输出里点明了当前 shell 处于翻译状态"
else
  ng "Apple Silicon + Rosetta：期望输出里提到 Rosetta（退出 ${CODE}）"
fi

#-- 5. --arch 取值要在动手前校验 ------------------------------------------
# 现在 --arch foo 会一路走到拼出 sing-box-<版本>-darwin-foo.tar.gz 才 404 死掉。
setup
sb install --arch foo --config "$ROOT/nope.json"
if [ "$CODE" != 0 ] && inlog "amd64" && inlog "arm64" && ! inlog "darwin-foo"; then
  ok "--arch foo：立即报错并点名合法取值，不会拼出 darwin-foo"
else
  ng "--arch foo：期望立即报错并点名 amd64 / arm64（退出 ${CODE}）"
fi

#-- 6. 合法的 --arch 仍要放行 ---------------------------------------------
setup
SB_FAKE_UNAME_M=x86_64 sb install --arch arm64 --config "$ROOT/nope.json"
if inlog "darwin-arm64"; then
  ok "--arch arm64：显式指定仍然生效"
else
  ng "--arch arm64：期望 darwin-arm64（退出 ${CODE}）"
fi

#-- 7. 非 macOS 要拒绝得清楚 ----------------------------------------------
# Windows 不是「没适配」，是另一个程序：launchctl / networksetup / plutil 都不存在。
# 但拒绝的时候得点名当前系统并说明为什么，而不是只丢一句「仅适用于 macOS」。
setup
SB_FAKE_UNAME_S=MINGW64_NT-10.0 sb status
if [ "$CODE" != 0 ] && inlog "MINGW64_NT-10.0" && inlog "launchd\|launchctl"; then
  ok "Git Bash：报错点名了当前系统并说明缺什么"
else
  ng "Git Bash：期望点名 MINGW64_NT-10.0 并说明原因（退出 ${CODE}）"
fi

setup
SB_FAKE_UNAME_S=Linux sb status
if [ "$CODE" != 0 ] && inlog "Linux" && inlog "launchd\|launchctl"; then
  ok "Linux/WSL：报错点名了当前系统并说明缺什么"
else
  ng "Linux/WSL：期望点名 Linux 并说明原因（退出 ${CODE}）"
fi

#-- 8. --help 在任何系统上都要能看 ----------------------------------------
# check_platform 特意排在参数解析之后，就是为了这个。别修回归了。
setup
SB_FAKE_UNAME_S=Linux sb --help
if [ "$CODE" = 0 ] && inlog "用法"; then
  ok "非 macOS 上 --help 仍可用（check_platform 排在参数解析之后）"
else
  ng "非 macOS 上 --help 应仍可用（退出 ${CODE}）"
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
