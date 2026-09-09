#!/usr/bin/env bash
#
# tests/logs.test.sh —— 日志体积管理。
#
# 复现的 bug：install 写的 plist 把 stdout/stderr 指向 /var/log/sing-box.{log,err}，
# 而全脚本没有任何一处轮转、截断、限额，连报告大小都没有。日志只涨不落，
# 而且**没有任何命令会告诉你它涨了**——实测这台机器上 sing-box.err 到了 271 MB，
# status / verify / doctor 一个字都没提过。
#
# 为什么不能靠 newsyslog 解决（这决定了修法）：
#   macOS 的 newsyslog 只会 rename + 新建，没有原地截断的选项（man newsyslog.conf
#   的 flags 里 B/C/D/G/J/N/U/Z 没有一个是 truncate）。而 StandardErrorPath 那个 fd
#   是 launchd 打开、dup2 到子进程 fd 2 上的——rename 之后守护进程继续往旧 inode 写，
#   也就是往已经被归档、甚至正在被 bzip2 的那个文件里写。新文件永远是空的。
#   sing-box 自己没法重开它（那不是它打开的），只有重启服务才会让 launchd 重新打开路径。
#   所以这里唯一安全的回收手段是**原地截断**：inode 不变，守护进程的 fd 继续有效。
#
# 全程离线、不要 sudo、不碰真实系统：--prefix 与 SB_LOGDIR 都指向临时目录。
# ⚠️ SB_LOGDIR 不只是测试后门——日志路径写死成绝对路径，是这个 bug 一直没法被
# 测试覆盖的直接原因。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"
pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -15 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box" "$ROOT/logs" "$ROOT/bin"
  # 只借 fixtures 里那个透传的 sudo 桩，别把整个 fixtures/bin 前置进来——
  # 那些 pgrep / launchctl 桩是给 update/verify 用的，在这里只会因为
  # SB_FAKE_STATE 未设置而报错，把判读搅浑。
  # 不装这个桩的话，logs 与 doctor 会卡在 sudo 密码提示上，那样它们就是
  # 「因为拿不到 sudo」而红，而不是「因为没有日志管理」而红——不算复现。
  cp tests/fixtures/bin/sudo "$ROOT/bin/sudo"; chmod 755 "$ROOT/bin/sudo"
  : > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"
  echo '{}' > "$ROOT/prefix/etc/sing-box/config.json"
  export SB_LOGDIR="$ROOT/logs"
  : > "$ROOT/logs/sing-box.log"
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf /tmp/.singbox-sh.lock 2>/dev/null
  ROOT=""
}
trap teardown EXIT

sb() { PATH="$ROOT/bin:$PATH" "$SB" --prefix "$ROOT/prefix" -y "$@" >"$LOG" 2>&1; CODE=$?; }
inlog() { grep -q "$1" "$LOG"; }

# 造一个 <MB> 大小的 .err。用 mkfile 般的稀疏写法，别真的写 100MB 出来。
big_err() {
  python3 - "$ROOT/logs/sing-box.err" "$1" <<'PY'
import sys
path, mb = sys.argv[1], int(sys.argv[2])
with open(path, "wb") as f:
    f.write(b"sing-box error line\n" * 64)
    f.truncate(mb * 1024 * 1024)
PY
}

fsize() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_size)' "$1"; }
finode() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }

echo "验证日志体积管理"

#-- 1. 日志路径必须可覆盖，否则这个 bug 根本没法被测试覆盖 -----------------
setup
# 往临时目录的 .log 里写一个独一无二的标记。读得到它，才证明 SB_LOGDIR 真的生效了；
# 光看「输出里没有 /var/log」会假绿——那个文件在真机上存在且是空的。
MARKER="SBLOGMARKER-$$-$(date +%s)"
printf '%s\n' "$MARKER" > "$ROOT/logs/sing-box.log"
big_err 200
sb logs 5
if [ "$CODE" = 0 ] && inlog "$MARKER"; then
  ok "SB_LOGDIR 生效：logs 读到了临时目录里的标记行"
else
  ng "SB_LOGDIR 未生效：logs 没读到标记行（退出 ${CODE}）"
fi

#-- 2. logs 要报告体积 ----------------------------------------------------
# 「失控」的前提是没人看得见。现在 logs 只会 tail，从不说这个文件有多大。
setup
big_err 200
sb logs
if [ "$CODE" = 0 ] && inlog "200" && inlog "MB"; then
  ok "logs：输出里报告了日志体积（200 MB）"
else
  ng "logs：期望报告体积（退出 ${CODE}）"
fi

#-- 3. 超过阈值时 status 必须主动告警 -------------------------------------
# 这条是这个 bug 的核心：涨到 271 MB 都没有任何命令提过一句。
setup
big_err 200
sb status
if inlog "日志占用" && inlog "logs truncate"; then
  ok "status：日志超阈值时报出体积并指向 logs truncate"
else
  ng "status：期望报出「日志占用」并指向 logs truncate（退出 ${CODE}）"
fi

#-- 4. 没超阈值时不许瞎报 -------------------------------------------------
setup
printf 'tiny\n' > "$ROOT/logs/sing-box.err"
sb status
if ! inlog "日志占用"; then
  ok "status：日志很小时不误报"
else
  ng "status：日志只有几字节却报了过大"
fi

#-- 5. logs truncate 要能回收空间 -----------------------------------------
setup
big_err 200
before=$(fsize "$ROOT/logs/sing-box.err")
sb logs truncate
after=$(fsize "$ROOT/logs/sing-box.err")
if [ "$CODE" = 0 ] && [ "$before" -gt 1000000 ] && [ "$after" = 0 ]; then
  ok "logs truncate：200 MB → 0，空间回收了"
else
  ng "logs truncate：期望截断到 0（退出 ${CODE}，${before} → ${after}）"
fi

#-- 6. 截断必须原地做，inode 不能变 ---------------------------------------
# 这是本修复的正确性核心。用 rm + touch 或 mv 的话 inode 会变，
# 而 launchd 持着旧 inode 的 fd——守护进程会继续往那个已经没有名字的文件里写，
# 磁盘一点都收不回来，而且从此再也看不到新日志。
setup
big_err 50
ino_before=$(finode "$ROOT/logs/sing-box.err")
sb logs truncate
ino_after=$(finode "$ROOT/logs/sing-box.err")
sz=$(fsize "$ROOT/logs/sing-box.err")
# ⚠️ 必须同时要求「确实截断到 0」。只比 inode 的话，命令压根没跑也会绿。
if [ "$sz" = 0 ] && [ "$ino_before" = "$ino_after" ]; then
  ok "logs truncate：截断到 0 且 inode 不变（原地截断，launchd 的 fd 仍有效）"
elif [ "$sz" != 0 ]; then
  ng "logs truncate：没有截断（大小仍为 ${sz}）"
else
  ng "logs truncate：inode 变了（${ino_before} → ${ino_after}）—— 守护进程会继续写旧 inode"
fi

#-- 7. doctor 也要把它列进判读 --------------------------------------------
setup
big_err 200
sb doctor
# ⚠️ 不能只 grep「日志」——doctor 的转储里本来就有「===== 日志 =====」这个段落标题，
# 那会假绿。要求它点名体积并给出回收命令。
if inlog "logs truncate" && inlog "MB"; then
  ok "doctor：判读里点出了超大日志并给出回收命令"
else
  ng "doctor：期望判读点名体积并指向 logs truncate（退出 ${CODE}）"
fi

#-- 8. 不要去装 newsyslog 配置 --------------------------------------------
# macOS 的 newsyslog 只 rename 不截断，而 StandardErrorPath 的 fd 由 launchd 持有：
# 轮转之后守护进程会继续往被归档的那个 inode 里写，新文件永远是空的。
# 装一份「看起来在管日志」但实际不工作的配置，比不装更糟。
setup
if ! grep -q 'newsyslog' "$SB"; then
  ok "不装 newsyslog 配置（与 launchd 持有 fd 的事实冲突）"
else
  if grep -n 'newsyslog' "$SB" | grep -qv '^[0-9]*:#'; then
    ng "脚本里出现了 newsyslog 的非注释用法" "$(grep -n newsyslog "$SB")"
  else
    ok "newsyslog 只出现在注释里（说明为什么不用它）"
  fi
fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
