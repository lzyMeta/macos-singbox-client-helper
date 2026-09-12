#!/usr/bin/env bash
#
# singbox.sh —— sing-box on macOS 全生命周期管理
#
# 配套《在 macOS 上直接运行 sing-box —— 配置最佳实践》
#
# 用法：singbox <命令> [参数]
#   install    首次安装（内核 + singbox 命令 + 系统层准备 + 配置 + 服务）
#   sysprep    只做系统层准备（换网络 / 插网卡后修复 IPv6 与 DNS）
#   status     服务状态、TUN 路由、监听端口
#   verify     完整验证清单（退出码 0 全过 / 1 链路档 / 2 策略档）
#   syscheck   系统层复查（换网络 / 换硬件后跑）
#   start | stop | restart
#   enable | disable
#   dns        系统 DNS：status / dhcp / backup / proxy / set <地址>
#   logs       [n|-f|size|truncate] 看日志、看体积、原地回收空间
#   debug      debug 前台跑，看分流命中
#   edit       改配置（校验 + 备份 + 重启）
#   config     配置子命令：show / backup / list / diff / restore
#   rules      验证规则集 URL
#   update     升级脚本与内核（先脚本，再沙箱验证 → 升级 → 验收，任一步失败自动回滚）
#   rollback   换回上一个内核与上一版 singbox 命令（$BIN.prev / $LAUNCHER.prev）并重新验收
#   mirror     GitHub 下载镜像：test / set <url> / show / reset
#   doctor     一键诊断
#   uninstall  卸载
#   help       同 -h
#
# 全局参数：
#   -y, --yes        非交互，所有询问取默认值
#   -q, --quiet      只输出警告与错误
#   -n, --dry-run    只打印将要执行的操作
#   --prefix <dir>   安装前缀（默认 /usr/local）
#   -h, --help       帮助
#   --version        脚本版本（单独使用时；跟在命令后是该命令的参数）
#
# 与自更新有关的环境变量：
#   SB_SELF_REPO      脚本自更新的来源仓库，默认 lzyMeta/macos-singbox-client-helper。
#                     fork 的人指到自己的 fork 用；测试指到假 repo 用
#   SB_SELF_UPDATED   =1 表示当前进程是阶段 S exec 出来的，update 会整段跳过阶段 S。
#                     走环境变量而不是命令行 flag：dispatch 对未知参数一律 die，
#                     用 flag 就要求新脚本认识旧脚本传的每一个参数，参数一改名，
#                     升级路径当场断在「未知参数」上 —— 而那条路径正是用来修 bug 的
#   SB_LOCK_INHERIT   =1 表示锁已由 exec 前的同一个 PID 持有。exec 保留 PID，
#                     不认它的话新进程会把自己判成「另一个正在运行的实例」
#
set -uo pipefail

VERSION="1.3.0"

#=======================================================================
# 全局变量与默认值
#=======================================================================
PREFIX="${SB_PREFIX:-/usr/local}"
BIN="$PREFIX/bin/sing-box"
ETC="$PREFIX/etc/sing-box"
CFG="$ETC/config.json"
# 脚本自己的安装位置。选 $PREFIX/bin 而不是 ~/bin，是因为它已经在所有 shell 的
# 默认 PATH 里 —— 不用碰 ~/.zshrc，自动化才算真的做完了；而 install 本来就已经
# need_root，不多要一次权限。
LAUNCHER="$PREFIX/bin/singbox"
PLIST=/Library/LaunchDaemons/sing-box.plist
LABEL=system/sing-box
# 日志目录。默认 /var/log，与 plist 里写死的绝对路径一致。
# 做成可覆盖不只是为了测试：路径写死正是「日志涨到几百 MB 也没有任何测试能发现」
# 的直接原因。install 时的取值会被烧进 plist，所以改了它就得重装服务。
LOGDIR="${SB_LOGDIR:-/var/log}"
LOGFILE="$LOGDIR/sing-box.log"
ERRFILE="$LOGDIR/sing-box.err"
# SB_LOCKDIR：测试用它把锁指到临时目录，免得与 live 的 singbox 命令、测试之间共用一把
LOCKDIR="${SB_LOCKDIR:-/tmp/.singbox-sh.lock}"
PREFS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/singbox"
PREFS="$PREFS_DIR/prefs"
DNS_BACKUP="$PREFS_DIR/dns-backup"
PROXY_DNS=1.1.1.1
# 日志体积告警阈值（MB）。launchd 把 stdout/stderr 直接怼进文件，只涨不落；
# 超过这个数 status 与 doctor 就点名，并指向 logs truncate。
LOG_WARN_MB="${SB_LOG_WARN_MB:-64}"
DEFAULT_EDITOR=vi
GH_API=https://api.github.com/repos/SagerNet/sing-box/releases/latest
GH_API_REPO=https://api.github.com/repos/SagerNet/sing-box
GH_DL=https://github.com/SagerNet/sing-box/releases/download
GH_RELEASES=https://github.com/SagerNet/sing-box/releases/latest

# 脚本自更新的来源。写死默认值，但留一个环境变量：fork 的人能指到自己的 fork，
# 测试能把阶段 S 指向假 repo 而不必依赖 URL 里的仓库名匹配。
# 与发布流程之间唯一的契约是「tag = v$VERSION、asset 名 = singbox.sh」，
# .github/workflows/release.yml 照着同一条约定写。
SELF_REPO="${SB_SELF_REPO:-lzyMeta/macos-singbox-client-helper}"
GH_SELF_API="https://api.github.com/repos/${SELF_REPO}/releases/latest"
GH_SELF_API_REPO="https://api.github.com/repos/${SELF_REPO}"
GH_SELF_DL="https://github.com/${SELF_REPO}/releases/download"
GH_SELF_RELEASES="https://github.com/${SELF_REPO}/releases/latest"
# config audit 报告里「解读」链接的前缀：迁移表里 fix != auto 的每条在这份文档里各有一节
# `### <id>`，报告详情区按 #<id> 锚过去。文档不装到本机，离线看不到是接受的代价。
# 钉在 v$VERSION 这个 tag 而不是 main：装在本机的脚本与它的迁移表是同一提交，文档也得是——
# main 往前走了、某条 id 撤了，旧脚本的链接不能跟着断。代价是 tag 推上去之前链接 404。
# tests/docs.test.sh 从这一行抓文件名与 docs/ 实际文件核对，改文件名两边一起改。
DOC_FINDINGS_URL="https://github.com/${SELF_REPO}/blob/v${VERSION}/docs/config-audit-findings.md"

# 前缀式镜像：把完整的 github 链接接在后面即可。
# 这类站点更替频繁，脚本一律先探测再用，探不通就换下一个。
# 可用 SB_MIRRORS 环境变量覆盖（空格分隔），或 mirror set 固定一个。
DEFAULT_MIRRORS="https://ghfast.top https://gh-proxy.com https://ghproxy.net https://mirror.ghproxy.com"
NET_TIMEOUT=25
CONNECT_TIMEOUT=4      # 建连超时：镜像死了要快速失败，不要干等
VERIFY_RETRY_WAIT=5    # 阶段 3 验收失败后隔多久重试那一轮
SANDBOX_WAIT=40        # 阶段 1 等沙箱实例监听起来的秒数。真实配置可能有几十个
                       # type=remote 的 rule_set，而沙箱缓存是空的，冷启动要现下一遍
PROBE_TIMEOUT=6        # 探测单个镜像的总时限
STALL_SECS=20          # 下载速度低于阈值持续这么久就放弃，换下一个
STALL_BYTES=2048

ASSUME_YES=0
QUIET=0
DRY=0
TMPFILES=()
SUDO_KEEPALIVE_PID=""
# 已持有互斥锁。acquire_lock 要可重入：cmd_update 持锁后还会经 cmd_restart
# 调到 cmd_stop / cmd_start，那几处也要取锁，不可重入就会自己把自己 die 掉。
#
# ⚠️ 阶段 S 的 exec 会带 SB_LOCK_INHERIT=1 进来。exec **保留 PID**，
# 不认这个变量的话，新进程会读 LOCKDIR/pid、kill -0 判活，认定「另一个实例
# 正在运行」—— 而那个 PID 就是它自己，于是等 3 轮然后 die，且此时脚本已经换过了。
# 锁文件里存的 PID 在 exec 后依然是对的，不必删了重建，也就没有竞态窗口。
LOCK_HELD="${SB_LOCK_INHERIT:-0}"
# 脚本自己拉起的后台 sing-box（install 第 5 步的前台试跑、update 阶段 1 的沙箱）。
# 不登记进来的话，Ctrl-C 时 cleanup 认不出它们，会留下占着 TUN 或沙箱端口的孤儿。
BG_PIDS=()
DEBUG_WAS_LOADED=0
DEBUG_RESTORED=0

#=======================================================================
# 输出
#=======================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_N=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_N=""
fi

ok()   { [ "$QUIET" = 1 ] || printf '%s  ✓%s %s\n' "$C_OK" "$C_N" "$*"; }
info() { [ "$QUIET" = 1 ] || printf '    %s\n' "$*"; }
dim()  { [ "$QUIET" = 1 ] || printf '%s    %s%s\n' "$C_DIM" "$*" "$C_N"; }
step() { [ "$QUIET" = 1 ] || printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_N"; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_N" >&2; }
bad()  { printf '%s  ✗ %s%s\n' "$C_ERR" "$*" "$C_N" >&2; }
die()  { bad "$*"; exit 1; }

# 验收失败计数，分两档——判据只有一条：**回滚到旧内核能不能把它换回来**。
#
#   链路档 vbad   节点链路断了、出口 IP 不对、冒出全局 IPv6。换内核有可能修好，该回滚。
#   策略档 vpbad  DNS 污染或解析手段全废、QUIC 没被挡住、国内直连失效、参照站点取不到
#                 数据。这些是路由策略与环境的问题，回滚一个都换不回来，反倒会让每次
#                 update 都在阶段 3 白白回滚一次。
#
# 两档都不许拿 warn 打发过去。warn 不计数，于是「测不了」和「测过了」在终端上长得
# 一模一样、退出码都是 0——那正是这套分档要消除的东西。cmd_verify 里凡是打 ✗ 的
# 分支都必须走 vbad / vpbad，否则失败会被函数末尾那条语句的退出码盖掉。
#
# 唯二的例外是第 1 步（服务未运行、SOCKS 不通）：那两处用裸 bad 加硬编码 return 1，
# 因为它们直接中断整个 cmd_verify，后面的计数根本不会被读到。退出码仍然是对的，
# 但别照着它们的样子在别处写裸 bad —— 只要函数还会继续往下走，就必须计数。
VERIFY_BAD=0
VERIFY_POLICY_BAD=0
vbad()  { VERIFY_BAD=$((VERIFY_BAD + 1)); bad "$*"; }
vpbad() { VERIFY_POLICY_BAD=$((VERIFY_POLICY_BAD + 1)); bad "$*"; }

#=======================================================================
# 基础设施：清理、锁、sudo、交互
#=======================================================================
cleanup() {
  local rc=$?
  [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  # 自己拉起的后台内核。只 TERM，绝不 KILL——强杀会留下残留路由。
  # sudo 拉起的那个 pid 是 sudo 自己，信号由它转发给子进程。
  local p
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && \
      { sudo -n kill -TERM "$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; }
  done
  for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do [ -n "$f" ] && rm -rf "$f" 2>/dev/null; done
  [ -d "$LOCKDIR" ] && [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCKDIR"
  return $rc
}
trap cleanup EXIT INT TERM

mktmp() { local t; t=$(mktemp "${1:-/tmp/singbox-XXXXXX}") || die "无法创建临时文件"; TMPFILES+=("$t"); printf '%s' "$t"; }
mktmpd() { local t; t=$(mktemp -d) || die "无法创建临时目录"; TMPFILES+=("$t"); printf '%s' "$t"; }
# 需要保留扩展名的临时文件。BSD 版 mktemp 要求 XXXXXX 必须在模板末尾，
# 不支持 sb-XXXXXX.json 这种后缀写法，所以改为「临时目录 + 固定文件名」。
mktmp_named() { local d; d=$(mktmpd); printf '%s/%s' "$d" "${1:-tmp.json}"; }

# 要留给用户事后查看、因而**不能**被 cleanup 删掉的文件（编辑失败的配置、doctor 转储）。
# 这些内容含真实订阅地址、节点凭据、访问过的域名，不能像以前那样按
# /tmp/<可预测名字> 直接落盘 —— 默认 umask 022 下那是 0644，同机任何用户都能读，
# 而 /tmp 还是 world-writable（可被预置符号链接）。mktemp -d 给的是 0700。
keep_path() {
  local d; d=$(mktemp -d "/tmp/singbox-keep-XXXXXX") || return 1
  chmod 700 "$d" 2>/dev/null
  printf '%s/%s' "$d" "${1:-keep}"
}

# 防并发：两个实例同时改配置或加载服务会出错
acquire_lock() {
  # 可重入：同一个进程再次调用直接放行。嵌套调用链确实存在——
  # cmd_update / _sb_rollback_to_prev → cmd_restart → cmd_stop / cmd_start。
  # 不这样做的话，锁里存的 $$ 会让 kill -0 判活成功、走不到残留清理分支，
  # 于是自己等自己，6 秒后 die，而那时二进制可能已经换掉了。
  [ "$LOCK_HELD" = 1 ] && return 0
  local tries=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    local pid; pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      warn "清理上次残留的锁（PID $pid 已不存在）"; rm -rf "$LOCKDIR"; continue
    fi
    tries=$((tries+1))
    [ "$tries" -gt 3 ] && die "另一个 singbox 实例正在运行（PID ${pid:-未知}）"
    info "等待另一个实例结束…"; sleep 2
  done
  echo "$$" > "$LOCKDIR/pid"
  LOCK_HELD=1
}

need_root() {
  [ "$DRY" = 1 ] && return 0
  if ! sudo -n true 2>/dev/null; then
    info "需要管理员权限（TUN 建虚拟网卡、改路由表必须 root）"
    sudo -v || die "未获得管理员权限"
  fi
  # 长任务期间保持凭据；父进程退出时自动收摊
  if [ -z "$SUDO_KEEPALIVE_PID" ]; then
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
  fi
}

run() { if [ "$DRY" = 1 ]; then dim "[dry-run] $*"; return 0; else eval "$@"; fi; }

# ask "问题" [y|n]  -> 0=yes
ask() {
  local q="$1" def="${2:-y}" a prompt
  [ "$def" = y ] && prompt="Y/n" || prompt="y/N"
  if [ "$DRY" = 1 ]; then dim "[dry-run] 询问：${q}（取默认 ${def}）"; [ "$def" = y ]; return; fi
  if [ "$ASSUME_YES" = 1 ]; then info "$q → 取默认（${def}）"; [ "$def" = y ]; return; fi
  if [ ! -t 0 ]; then info "$q → 非交互，取默认（${def}）"; [ "$def" = y ]; return; fi
  read -r -p "    $q [$prompt] " a </dev/tty || a=""
  a="${a:-$def}"
  [[ "$a" =~ ^[Yy]$ ]]
}

#=======================================================================
# 前置检查
#=======================================================================
# 只跑在 macOS 上。这不是「还没适配」，是产品边界：服务管理靠 launchd（launchctl +
# LaunchDaemon plist）、网络与 DNS 靠 networksetup / scutil / dscacheutil、
# 配置校验靠 plutil —— 这些在 Windows 与 Linux 上一个都不存在，换平台等于另写一个程序。
# 所以这里只求拒绝得清楚：点名当前系统，说明缺的是什么。
check_platform() {
  local sys; sys=$(uname -s 2>/dev/null)
  [ "$sys" = Darwin ] && return 0
  bad "本脚本只支持 macOS，当前系统是 ${sys:-未知}"
  case "$sys" in
    Linux)      info "WSL 与 Linux 上没有 launchd / networksetup —— 用 systemd 单元自己起 sing-box" ;;
    MINGW*|MSYS*|CYGWIN*)
                info "Windows 上没有 launchd / networksetup —— 用 sing-box 官方的 Windows 版与服务安装方式" ;;
    *)          info "服务管理依赖 launchd，网络与 DNS 依赖 networksetup / scutil，本平台都没有" ;;
  esac
  info "内核本身是跨平台的，跨不过去的是这套系统层集成：$GH_RELEASES"
  exit 1
}

check_deps() {
  local missing=()
  for c in curl python3 networksetup launchctl plutil; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ ${#missing[@]} -gt 0 ] && die "缺少必需命令：${missing[*]}"
  command -v dig >/dev/null 2>&1 || dim "未安装 dig，DNS 检查会降级（brew install bind 可补上）"
  return 0
}

require_installed() {
  [ -x "$BIN" ] || die "未找到 $BIN —— 先运行：$(basename "$0") install"
  [ -f "$CFG" ] || die "未找到配置 $CFG —— 先运行：$(basename "$0") install"
}

# 当前 shell 是否跑在 Rosetta 2 的翻译层里。
# 真机实测的键语义：Intel 上 sysctl.proc_translated **不存在**（sysctl 退出 1）；
# Apple Silicon 上它存在，原生为 0、被翻译时为 1。
is_translated() { [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; }

# 硬件是不是 Apple Silicon。hw.optional.arm64 在 Intel 上同样不存在。
is_apple_silicon() { [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; }

# 该装哪个架构的内核。
#
# ⚠️ 不能只看 `uname -m`：它报的是**当前进程**的架构，不是硬件的。
# Apple Silicon 上被 Rosetta 翻译的 shell 里（Rosetta 方式打开的终端、x86_64 的
# Homebrew bash、arch -x86_64 bash……）它会说 x86_64，于是我们会在 ARM 机器上装
# Intel 内核——一个常驻的网络路径守护进程被塞进翻译层，而且 cmd_update 走同一个
# 函数，会把这个错误一直续下去。硬件判据只有 hw.optional.arm64 一条。
detect_arch() {
  is_apple_silicon && { echo arm64; return 0; }
  case "$(uname -m)" in
    arm64)  echo arm64 ;;
    x86_64) echo amd64 ;;
    *)      echo "" ;;
  esac
}

# 合法的架构取值。放在这里是为了让 install --arch 能在动手之前就否掉错的，
# 而不是一路拼出 sing-box-<版本>-darwin-foo.tar.gz 再靠 404 失败。
arch_valid() { case "${1:-}" in amd64|arm64) return 0 ;; *) return 1 ;; esac; }

running() { pgrep -x sing-box >/dev/null 2>&1; }
daemon_loaded() { sudo launchctl print "$LABEL" >/dev/null 2>&1; }

# 从配置读取 mixed/socks 监听地址
sock_addr() {
  python3 - "$CFG" <<'PY' 2>/dev/null || echo "127.0.0.1:10808"
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for i in d.get("inbounds",[]):
        if i.get("type") in ("mixed","socks"):
            print(f'{i.get("listen","127.0.0.1")}:{i.get("listen_port",10808)}'); break
    else:
        print("127.0.0.1:10808")
except Exception:
    print("127.0.0.1:10808")
PY
}

json_valid() { python3 -m json.tool "$1" >/dev/null 2>&1; }

#-----------------------------------------------------------------------
# 网络：GitHub 直连失败时自动切换镜像
#-----------------------------------------------------------------------
# 候选镜像列表：环境变量 > 已保存偏好（置顶）> 内置默认
mirror_list() {
  local saved
  if [ -n "${SB_MIRRORS:-}" ]; then printf '%s' "$SB_MIRRORS"; return; fi
  saved=$(prefs_get mirror 2>/dev/null) || saved=""
  if [ -n "$saved" ]; then
    # 把记住的那个排在最前，其余保留作为后备
    printf '%s' "$saved $(printf '%s' "$DEFAULT_MIRRORS" | tr ' ' '\n' | grep -vFx "$saved" | tr '\n' ' ')"
  else
    printf '%s' "$DEFAULT_MIRRORS"
  fi
}

# 拼接镜像地址：多数前缀式镜像直接把完整 URL 接在后面
mirror_url() {
  local prefix="$1" url="$2"
  printf '%s/%s' "${prefix%/}" "$url"
}

# 探测一个 URL 是否可下载（只取头部，不拉全量）
probe_url() {
  local url="$1" t="${2:-$PROBE_TIMEOUT}"
  curl -fsIL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$t" -o /dev/null "$url" 2>/dev/null
}

# 人类可读的字节数
human_size() {
  local b="${1:-0}"
  if [ "$b" -ge 1048576 ] 2>/dev/null; then printf '%d.%d MB' $((b/1048576)) $(((b%1048576)*10/1048576))
  elif [ "$b" -ge 1024 ] 2>/dev/null; then printf '%d KB' $((b/1024))
  else printf '%s B' "$b"; fi
}

#-----------------------------------------------------------------------
# 日志体积
#
# plist 把 stdout/stderr 直接指向文件，launchd 只管往里写，不轮转、不封顶。
# 实测能涨到几百 MB 而没有任何命令提过一句——「失控」的前提是没人看得见。
#
# ⚠️ 回收只能**原地截断**，不能 rename / rm 后重建。
# StandardErrorPath 那个 fd 是 launchd 打开、dup2 到子进程 fd 2 上的：
# 换了 inode，守护进程就一直往那个已经没有名字的旧文件里写——磁盘一点收不回来，
# 而且从此再也看不到新日志。这也是不给它配 newsyslog 的原因：
# macOS 的 newsyslog 只会 rename + 新建（man newsyslog.conf 的 flags 里
# B/C/D/G/J/N/U/Z 没有一个是截断），装上去等于装了一个看着在管、实际不工作的东西。
#-----------------------------------------------------------------------
# 单个文件的字节数，读不到就是 0
log_bytes() {
  [ -f "$1" ] || { printf 0; return 0; }
  local n; n=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  printf '%s' "${n:-0}"
}

# 两个日志文件的总字节数
log_total_bytes() {
  printf '%s' "$(( $(log_bytes "$LOGFILE") + $(log_bytes "$ERRFILE") ))"
}

# 超过阈值就打一条告警并指路。没超就什么都不说。被 status 与 doctor 共用。
# 返回 0 = 超了。
log_size_warn() {
  local total limit
  total=$(log_total_bytes)
  limit=$(( LOG_WARN_MB * 1024 * 1024 ))
  [ "$total" -gt "$limit" ] || return 1
  warn "日志占用 $(human_size "$total")（阈值 ${LOG_WARN_MB} MB）—— launchd 不会自己轮转"
  info "回收：$(basename "$0") logs truncate（原地截断，不重启服务）"
  return 0
}

# 带镜像回退的下载：download <目标文件> <github原始URL> [描述]
# 直连优先；失败则逐个试镜像；成功的镜像会被记住供后续使用
download() {
  local out="$1" url="$2" desc="${3:-文件}" want_sha="${4:-}"

  # 进度条走 stderr。之前整条命令带了 2>/dev/null，把进度条也吞掉了。
  local -a opts=(-fL --connect-timeout "$CONNECT_TIMEOUT" --max-time 600
                 --speed-time "$STALL_SECS" --speed-limit "$STALL_BYTES" --retry 1)
  local show_progress=0
  if [ "$QUIET" = 1 ]; then
    opts+=(-s)
  elif [ -t 2 ]; then
    opts+=(--progress-bar); show_progress=1
  else
    opts+=(-s)   # 非终端（管道、日志）下进度条只会刷屏
  fi

  # 逐个候选源：先花几秒探测，通了才真正下载
  local -a sources=("$url")
  local m
  for m in $(mirror_list); do sources+=("$(mirror_url "$m" "$url")"); done

  local i=0 src label t0 t1 sz
  for src in "${sources[@]}"; do
    i=$((i+1))
    if [ "$i" = 1 ]; then label="直连 github.com"; else label="镜像 $(printf '%s' "$src" | cut -d/ -f1-3)"; fi

    # 这几条以前是裸 printf，-q 之下照样刷屏。ok/info/dim 都带 QUIET 前缀，这里也要带。
    [ "$QUIET" = 1 ] || printf '    [%d/%d] 探测 %s … ' "$i" "${#sources[@]}" "$label"
    if ! probe_url "$src" "$PROBE_TIMEOUT"; then
      [ "$QUIET" = 1 ] || printf '%s不通%s\n' "$C_DIM" "$C_N"
      continue
    fi
    [ "$QUIET" = 1 ] || printf '%s可用%s\n' "$C_OK" "$C_N"

    info "下载${desc} ← ${label}"
    t0=$(date +%s)
    if curl "${opts[@]}" -o "$out" "$src" && [ -s "$out" ]; then
      t1=$(date +%s)
      sz=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
      ok "下载完成：$(human_size "${sz:-0}")，耗时 $((t1-t0))s"
      if [ -n "$want_sha" ]; then
        local got; got=$(shasum -a 256 "$out" 2>/dev/null | awk '{print $1}')
        if [ "$got" != "$want_sha" ]; then
          bad "sha256 不匹配 —— 丢弃这一份"
          info "期望 $want_sha"
          info "实得 ${got:-（算不出）}"
          rm -f "$out" 2>/dev/null
          if [ "$i" = 1 ]; then die "直连 github.com 下来的文件都对不上，别再往下走了"; fi
          warn "换下一个来源"
          continue
        fi
        ok "sha256 校验通过"
      fi
      if [ "$i" -gt 1 ]; then
        prefs_set mirror "$(printf '%s' "$src" | cut -d/ -f1-3)" >/dev/null 2>&1 \
          && dim "已记住该镜像，后续优先使用（直连仍排在最前）"
      fi
      return 0
    fi
    [ "$show_progress" = 1 ] && echo
    warn "从 ${label} 下载失败或中断，换下一个"
    rm -f "$out" 2>/dev/null
  done

  bad "所有来源均不可用（直连 + ${#sources[@]} 个候选）"
  info "可手动下载后用 install --version <版本> 跳过；或用 SB_MIRRORS 指定自己的镜像"
  return 1
}

# 取最新版本号：API 直连 → API 走镜像 → 解析 releases/latest 的跳转地址
#
# latest_version [api_url] [releases_url]
# 默认查 sing-box 内核；阶段 S 传自家 repo 的两个地址复用同一套镜像与兜底逻辑。
latest_version() {
  local v m
  local api="${1:-$GH_API}"
  local rel="${2:-$GH_RELEASES}"
  v=$(curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$NET_TIMEOUT" "$api" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }

  for m in $(mirror_list); do
    printf '    查询版本 ← %s … ' "$m" >&2
    v=$(curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time 12 \
        "$(mirror_url "$m" "$api")" 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$v" ]; then printf '%s\n' "$v" >&2; printf '%s' "$v"; return 0; fi
    printf '%s无结果%s\n' "$C_DIM" "$C_N" >&2
  done

  # 最后一招：releases/latest 会 302 到 .../tag/vX.Y.Z
  v=$(curl -fsIL --connect-timeout "$CONNECT_TIMEOUT" --max-time 15 "$rel" 2>/dev/null \
      | sed -n 's|.*location:.*/tag/v\([0-9][^[:space:]]*\).*|\1|Ip' | tail -1 | tr -d '\r')
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 1
}

# 取某个 release 里某个 asset 的 sha256。拿不到就回空，由调用方决定降级还是硬失败。
#
# 上游 release 里确实没有 checksums.txt（1.14.0 的 167 个 asset 逐个看过），
# 但 GitHub Releases API 的每个 asset 现在带 digest 字段（"sha256:<hex>"），
# 校验值改从这里拿即可。macOS 自带 shasum -a 256，不引入新依赖。
#
# ⚠️ 这道校验能挡的是「传输损坏」和「单个镜像投毒」。
# API 本身也可能是经镜像拿到的——那种情况下 digest 的可信度不高于那个镜像，
# 挡不住「API 与文件出自同一个坏镜像」。别把它当成签名。
asset_digest() {
  # ⚠️ 别把 api 并进上面那条 local：bash 在执行 local 之前就把整行参数展开完了，
  # 同一条语句里引用不到前面刚声明的变量，${ver#v} 会展开成空串，
  # URL 变成 .../tags/v，取不到 digest —— 而调用方只会 warn 一句「取不到」照常下载，
  # 整道校验就这么静默失效了。
  local ver="$1" name="$2" body m api
  # ⚠️ 同样别把它并进上面那条 local —— 理由见上面那段注释。
  local repo_api="${3:-$GH_API_REPO}"
  api="$repo_api/releases/tags/v${ver#v}"
  body=$(curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$NET_TIMEOUT" "$api" 2>/dev/null)
  if [ -z "$body" ]; then
    for m in $(mirror_list); do
      body=$(curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time 12 \
             "$(mirror_url "$m" "$api")" 2>/dev/null)
      [ -n "$body" ] && break
    done
  fi
  [ -n "$body" ] || return 1
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
want = sys.argv[1]
for a in d.get("assets", []):
    if a.get("name") == want:
        dg = a.get("digest") or ""
        if dg.startswith("sha256:"):
            print(dg[7:])
        break
' "$name" 2>/dev/null
}

#-----------------------------------------------------------------------
# 偏好设置（用户级，不需要 root）
#-----------------------------------------------------------------------
prefs_get() {
  local key="$1"
  [ -f "$PREFS" ] || return 1
  local v
  v=$(grep -E "^${key}=" "$PREFS" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$v" ] || return 1
  # 去掉可能存在的成对引号
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

prefs_set() {
  local key="$1" val="$2"
  mkdir -p "$PREFS_DIR" 2>/dev/null || { warn "无法创建 ${PREFS_DIR}，本次设置不会保存"; return 1; }
  local tmp; tmp=$(mktmp)
  [ -f "$PREFS" ] && grep -vE "^${key}=" "$PREFS" > "$tmp" 2>/dev/null
  printf "%s='%s'\n" "$key" "$val" >> "$tmp"
  mv "$tmp" "$PREFS" && chmod 600 "$PREFS" 2>/dev/null
}

prefs_unset() {
  local key="$1"
  [ -f "$PREFS" ] || return 0
  local tmp; tmp=$(mktmp)
  grep -vE "^${key}=" "$PREFS" > "$tmp" 2>/dev/null
  mv "$tmp" "$PREFS"
}

# 编辑器是否可用（只验第一个词，允许带参数如 "code -w"）
editor_usable() {
  local cmd="${1%% *}"
  [ -n "$cmd" ] || return 1
  command -v "$cmd" >/dev/null 2>&1
}

# 解析本次要用的编辑器
# 优先级：--editor 参数 > 已保存偏好 > $EDITOR > vi
# 任一级不可用则依次降级，并说明原因
resolve_editor() {
  local want="${1:-}" ed=""
  if [ -n "$want" ]; then
    if editor_usable "$want"; then printf '%s' "$want"; return 0; fi
    warn "指定的编辑器不可用：$want"
  fi
  ed=$(prefs_get editor) || ed=""
  if [ -n "$ed" ]; then
    if editor_usable "$ed"; then printf '%s' "$ed"; return 0; fi
    warn "已保存的编辑器不可用：$ed —— 将回退，并清除该偏好"
    prefs_unset editor
  fi
  if [ -n "${EDITOR:-}" ] && editor_usable "$EDITOR"; then
    printf '%s' "$EDITOR"; return 0
  fi
  if editor_usable "$DEFAULT_EDITOR"; then
    printf '%s' "$DEFAULT_EDITOR"; return 0
  fi
  return 1
}

# 备份当前配置。路径走 stdout，成败走返回码 —— 两者别混。
# ⚠️ 之前最后一条语句是 printf，函数返回码恒为它的 0：sudo cp 失败（卷满、只读）
# 时调用方照样往下走，把配置覆盖掉而没有任何备份。判据只能用 run 的返回码，
# 不能用 [ -f "$bak" ] —— dry-run 下 run 返回 0 但文件本来就不该存在。
backup_config() {
  local bak="$CFG.$(date +%Y%m%d-%H%M%S).bak" rc=0
  run "sudo cp '$CFG' '$bak'" || rc=1
  [ "$rc" = 0 ] && info "已备份：$bak"
  printf '%s' "$bak"
  return $rc
}

# 只保留最近 N 份备份，避免无限堆积
prune_backups() {
  local keep="${1:-10}"
  local n; n=$(ls -1t "$CFG".*.bak 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -le "$keep" ] && return 0
  ls -1t "$CFG".*.bak 2>/dev/null | tail -n +$((keep+1)) | while read -r f; do
    run "sudo rm -f '$f'"
  done
  dim "已清理旧备份，保留最近 $keep 份"
}

network_services() {
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | grep -v '^$'
}

#-----------------------------------------------------------------------
# 系统 DNS 的切换与还原
#
# 代理运行时需要把 DNS 指向非局域网地址（否则查询不进 TUN，明文出网被投毒）；
# 代理停掉后这个设置反而有害——1.1.1.1 明文查询在国内一样会被污染，
# 所以停止 / 停用 / 卸载时要还原回路由器下发的地址。
#-----------------------------------------------------------------------
dns_backup_save() {
  [ "$DRY" = 1 ] && { dim "[dry-run] 记录各网络服务当前 DNS 到 $DNS_BACKUP"; return 0; }
  mkdir -p "$PREFS_DIR" 2>/dev/null || return 1
  : > "$DNS_BACKUP"
  local svc d
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    d=$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
    case "$d" in *"aren't any"*) d="empty" ;; esac
    # 若当前已经是代理用的 DNS（之前手动设过或上次没还原干净），
    # 记它没有意义——还原时会原样写回代理 DNS。一律记为 empty，交回 DHCP。
    [ "$d" = "$PROXY_DNS" ] && d="empty"
    printf '%s\t%s\n' "$svc" "$d" >> "$DNS_BACKUP"
  done <<< "$(network_services)"
  chmod 600 "$DNS_BACKUP" 2>/dev/null
  dim "已记录原 DNS 设置（还原时用）"
}

# 把所有网络服务的 DNS 设为代理用的地址
dns_apply_proxy() {
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    run "sudo networksetup -setdnsservers \"$svc\" $PROXY_DNS 2>/dev/null || true"
  done <<< "$(network_services)"
  run "sudo dscacheutil -flushcache"
}

# 还原：有备份就按备份还原，没有就交回 DHCP（即路由器下发）
# dns_restore [backup|dhcp|<地址...>]
#   backup（默认）：按 install 前记录的原值逐条回滚，无备份则交回 DHCP
#   dhcp          ：全部交回 DHCP（路由器下发），忽略备份
#   <地址>        ：全部设为指定地址
dns_restore() {
  local target="${1:-backup}"
  local svc saved restored=0

  if [ "$target" = "dhcp" ]; then
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      run "sudo networksetup -setdnsservers \"$svc\" empty 2>/dev/null || true"
      info "  $svc → 路由器下发（DHCP）"
    done <<< "$(network_services)"
    run "sudo dscacheutil -flushcache"
    ok "系统 DNS 已交回 DHCP"
    _dns_show_current
    return 0
  fi

  if [ "$target" != "backup" ]; then
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      run "sudo networksetup -setdnsservers \"$svc\" $target 2>/dev/null || true"
      info "  $svc → $target"
    done <<< "$(network_services)"
    run "sudo dscacheutil -flushcache"
    ok "系统 DNS 已设为 $target"
    _dns_show_current
    return 0
  fi

  if [ -f "$DNS_BACKUP" ]; then
    while IFS=$'\t' read -r svc saved; do
      [ -n "$svc" ] || continue
      # 备份里若混进了代理 DNS（旧版本脚本或手动设过），一律按 DHCP 处理
      if [ "$saved" = "empty" ] || [ -z "$saved" ] || [ "$saved" = "$PROXY_DNS" ]; then
        run "sudo networksetup -setdnsservers \"$svc\" empty 2>/dev/null || true"
        info "  $svc → 路由器下发（DHCP）"
      else
        run "sudo networksetup -setdnsservers \"$svc\" $saved 2>/dev/null || true"
        info "  $svc → $saved"
      fi
      restored=1
    done < "$DNS_BACKUP"
  fi
  if [ "$restored" = 0 ]; then
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      run "sudo networksetup -setdnsservers \"$svc\" empty 2>/dev/null || true"
      info "  $svc → 路由器下发（DHCP）"
    done <<< "$(network_services)"
  fi
  run "sudo dscacheutil -flushcache"
  ok "系统 DNS 已还原"
  _dns_show_current
}

# 还原后回读实际生效值，避免"以为还原了其实没有"
_dns_show_current() {
  [ "$DRY" = 1 ] && return 0
  local svc d warned=0
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    d=$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
    case "$d" in *"aren't any"*) d="（DHCP 下发）" ;; esac
    printf '      %-26s %s\n' "$svc" "$d"
    [ "$d" = "$PROXY_DNS" ] && warned=1
  done <<< "$(network_services)"
  [ "$warned" = 1 ] && warn "仍有服务指向 $PROXY_DNS —— 用 dns dhcp 强制交回 DHCP"
  return 0
}

# 当前是否处于"代理用的 DNS"状态
dns_is_proxy_mode() {
  local svc d
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    d=$(networksetup -getdnsservers "$svc" 2>/dev/null | tr -d ' \n')
    [ "$d" = "$PROXY_DNS" ] && return 0
  done <<< "$(network_services)"
  return 1
}

# dns_restore 的自定义地址分支会把 $target 不加引号地拼进 run()，而 run() 是 eval——
# 不校验的话 `dns set '1.1.1.1; <命令>'` 会在 eval 阶段被执行。
# 校验字符集而不是写严格 IP 正则：既容得下 IPv4 / IPv6 / 空格分隔的多个地址，
# 又不会误伤合法输入。empty 是 networksetup 用来清空 DNS 的字面量，单独放行。
_dns_addr_ok() {
  local t
  [ -n "${1:-}" ] || return 1
  for t in $1; do
    [ "$t" = empty ] && continue
    case "$t" in
      *[!0-9A-Fa-f.:]*) return 1 ;;
      *[0-9A-Fa-f]*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

is_private_dns() {
  case "$1" in
    192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|*"aren't any"*|"") return 0 ;;
    *) return 1 ;;
  esac
}


# 把一份脚本安装成 $LAUNCHER（默认 /usr/local/bin/singbox）。
# 退路语义与内核的 $BIN / $BIN.prev 完全对称：旧的先存成 .prev，再让新的就位。
#
# ⚠️ 就位这一步必须是 mv（rename），不能用 cp / install 直接覆盖。
# bash 是**边执行边按偏移量读脚本文件**的：cp 覆盖的是同一个 inode，正在跑的那个
# 进程下一次读取会读到新文件的字节流、落在错误的偏移上 —— 症状是执行到一半冒出
# 莫名其妙的语法错误，且只在「脚本更新自己」这一条路径上出现。mv 换的是目录项，
# 旧 inode 被 unlink 但仍被打开着，当前进程读到的还是那一份完整的旧内容。
# singbox-selfcheck.sh 第 13 项守着这一条。
#
# _install_launcher <源文件> [说明]
_install_launcher() {
  local src="$1"
  local desc="${2:-singbox 命令}"
  [ -f "$src" ] || { bad "找不到要安装的脚本：$src"; return 1; }

  if [ "$DRY" = 1 ]; then
    dim "[dry-run] 安装 ${desc} → ${LAUNCHER}（已存在则旧的先存成 ${LAUNCHER}.prev）"
    return 0
  fi

  # 装一份语法就坏了的脚本，等于把用户的 singbox 命令弄死，而他下一次才会发现。
  bash -n "$src" 2>/dev/null || { bad "脚本语法检查未通过，不安装：$src"; return 1; }

  # 先在**目标所在的同一个文件系统**上落一份临时文件。mv 跨文件系统会退化成
  # copy + unlink，那就又回到「覆盖同一个 inode」的老问题上了。
  local staged="$LAUNCHER.new.$$"
  sudo mkdir -p "$PREFIX/bin" || { bad "建不了 $PREFIX/bin"; return 1; }
  sudo cp "$src" "$staged" || { bad "写不进 $PREFIX/bin"; return 1; }
  sudo chmod 755 "$staged"
  sudo xattr -d com.apple.quarantine "$staged" 2>/dev/null || true

  if [ -f "$LAUNCHER" ]; then
    sudo mv -f "$LAUNCHER" "$LAUNCHER.prev" || {
      sudo rm -f "$staged"
      bad "存不下旧的 ${LAUNCHER}.prev，不动 ${LAUNCHER}"
      return 1
    }
  fi
  sudo mv -f "$staged" "$LAUNCHER" || { bad "装不上 $LAUNCHER"; return 1; }
  return 0
}


# 版本比较：a 严格大于 b 才返回 0。
# ⚠️ 不能用 sort -V —— GNU 专有，自检第 4 项直接禁掉它。
# 按 . 切三段做数值比较，非数字段一律当 0（1.2.0-rc1 的第三段按 0 算，
# 于是预发布不会被判成比正式版新）。
ver_gt() {
  local a="${1#v}"
  local b="${2#v}"
  local i av bv
  for i in 1 2 3; do
    av=$(printf '%s' "$a" | cut -d. -f"$i")
    bv=$(printf '%s' "$b" | cut -d. -f"$i")
    case "$av" in ''|*[!0-9]*) av=0 ;; esac
    case "$bv" in ''|*[!0-9]*) bv=0 ;; esac
    [ "$av" -gt "$bv" ] && return 0
    [ "$av" -lt "$bv" ] && return 1
  done
  return 1
}

# 阶段 S：脚本更新自己。永远排在内核三阶段**之前** —— 这样内核升级用的总是最新的
# 升级逻辑，而历史上出问题的恰恰是升级逻辑本身而不是内核。
#
# 这个函数的返回值不影响内核阶段：取不到新版（无 release、GitHub 与所有镜像
# 均不可达）、下载失败、语法不过，一律 warn 一句就返回 0 照升内核。脚本更新
# 不该有权阻断用户真正要的那件事，何况内核升级自带沙箱与回滚。
#
# 换成功且当前进程就是从 $LAUNCHER 启动的话，本函数以 exec 收尾，不返回。
_self_update() {
  step "阶段 S/3　脚本自更新"

  if [ "$DRY" = 1 ]; then
    dim "[dry-run] 查 ${SELF_REPO} 的 latest release，与本地 v${VERSION} 比对"
    dim "[dry-run] 远端更新则下载 singbox.sh、bash -n、原子替换 ${LAUNCHER}，再 exec 新脚本继续"
    return 0
  fi

  local new
  new=$(latest_version "$GH_SELF_API" "$GH_SELF_RELEASES") || new=""
  if [ -z "$new" ]; then
    warn "取不到脚本的最新版本（${SELF_REPO} 还没有 release，或 GitHub 与所有镜像均不可达）"
    info "跳过脚本自更新，继续升级内核"
    return 0
  fi
  new="${new#v}"
  info "脚本：本地 v${VERSION}，远端 v${new}"

  # 只有严格大于才升。相等或更小一律不动 —— release 被回退时把用户降级，
  # 等于把已经修好的 bug 再装回去。
  if ! ver_gt "$new" "$VERSION"; then
    ok "脚本已是最新（v${VERSION}）"
    return 0
  fi

  local tmpd; tmpd=$(mktmpd)
  local want_sha; want_sha=$(asset_digest "$new" "singbox.sh" "$GH_SELF_API_REPO") || want_sha=""
  if [ -n "$want_sha" ]; then dim "校验值来自 GitHub API：${want_sha}"
  else warn "取不到 singbox.sh 的 sha256 —— 本次不做完整性校验"; fi

  # ⚠️ 必须在子 shell 里调 download。它在「直连下来的文件 sha256 对不上」那一档
  # 走的是 die 而不是 return（见 download 内部 `[ "$i" = 1 ] && die`），
  # 那个 die 会从这里的 `if !` 底下穿过去，把整条 update 打死在阶段 S ——
  # 阶段 0-3 一个字节都跑不到，而那正是「脚本更新不该阻断用户真正要的那件事」
  # 要防的。套一层 ( ) 让 die 只杀子 shell，退出码照常回到这里。
  #
  # 子 shell 是安全的：bash 3.2 的 ( ) **不继承 EXIT trap**（实测过），所以
  # cleanup 不会在子 shell 退出时跑 —— 否则它会把 $tmpd 连同刚下好的文件、
  # 以及本进程持有的 $LOCKDIR 一起删掉（子 shell 里 $$ 仍是父进程的 PID）。
  # download 只往 $out 写文件，不往 TMPFILES 里登记东西，没有别的状态要带回来。
  if ! ( download "$tmpd/singbox.sh" "$GH_SELF_DL/v${new}/singbox.sh" "脚本 v$new" "$want_sha" ); then
    warn "脚本 v${new} 下载或校验失败，跳过自更新，继续升级内核"
    return 0
  fi

  # 装一份语法就坏了的脚本等于把用户的 singbox 命令弄死，而他下一次才会发现。
  # _install_launcher 里还会再验一道，这里先验是为了能说清「为什么没换」。
  if ! bash -n "$tmpd/singbox.sh" 2>/dev/null; then
    warn "下载到的 singbox.sh 语法检查未通过，不替换 —— 继续升级内核"
    return 0
  fi

  local had_launcher=0
  [ -f "$LAUNCHER" ] && had_launcher=1

  if ! _install_launcher "$tmpd/singbox.sh" "脚本 v$new"; then
    warn "脚本没换上，继续升级内核"
    return 0
  fi
  ok "singbox 命令已更新到 v${new}（${LAUNCHER}）"
  [ "$had_launcher" = 1 ] || \
    warn "启动器原本不在 ${LAUNCHER}，已按当前 --prefix 装入"

  # 当前进程是不是就是从 $LAUNCHER 启动的。
  # 两边都过一次 cd + pwd，把 $0 这类相对路径（`./singbox.sh`）绝对化之后再比 ——
  # 不绝对化的话，从 $LAUNCHER 启动的进程也会因为写法不同而被判成「仓库副本」。
  #
  # ⚠️ 这**不解析符号链接**：bash 的 cd 与 pwd 默认都是 -L 逻辑路径，
  # `cd /var/tmp && pwd` 回的仍是 /var/tmp 而不是 /private/var/tmp。
  # 所以 $PREFIX/bin 若是一条符号链接，两边字符串仍可能不等，本该 re-exec 的
  # 场景会退化成「只更新不重启」—— 那是安全的降级（脚本已经换好了，只是这一次
  # 继续用旧的跑完），不是数据损坏。真要解链接得手写循环读 `ls -l`：
  # readlink -f 在 macOS 上不存在，也被自检第 4 项禁了，为这个边缘场景不值当。
  # 默认 --prefix /usr/local 下 /usr/local/bin 不是符号链接，无实际影响。
  local self_dir; self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  local self_src="${self_dir:-$(dirname "$0")}/$(basename "$0")"
  local lch_dir; lch_dir=$(cd "$(dirname "$LAUNCHER")" 2>/dev/null && pwd)
  local lch_real="${lch_dir:-$(dirname "$LAUNCHER")}/$(basename "$LAUNCHER")"

  if [ "$self_src" != "$lch_real" ]; then
    warn "你跑的是 ${self_src}，本次更新的是 ${LAUNCHER}"
    info "这份副本请自行 git pull 更新。不重新执行 —— 继续用当前脚本升级内核"
    return 0
  fi

  # ⚠️ exec 不触发 EXIT trap，TMPFILES 里的临时目录会泄漏。走之前显式清掉。
  local f
  for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do [ -n "$f" ] && rm -rf "$f" 2>/dev/null; done
  TMPFILES=()

  # ⚠️ SUDO_KEEPALIVE_PID 在这里丢掉，但那个后台循环的条件是 kill -0 $$，
  # exec 后 PID 没变，所以它继续活着、票据继续续期（这是好事）。新进程不知道
  # 它存在，会再起一个 —— 多一个循环无害且随进程退出自终。别当成 bug 去「修」。
  ok "换上新脚本，重新执行以继续升级内核"

  # ⚠️ 开关走环境变量，不走命令行 flag。顶层 dispatch 对未知参数一律 die，
  # 用 --skip-self 这种 flag 就意味着**旧脚本 exec 新脚本时，新脚本必须认识
  # 旧脚本传的每一个参数**；哪天参数改名，升级路径当场断在「未知参数」上，
  # 而这条路径恰恰是用来修 bug 的。未知环境变量不会让谁 die。
  export SB_SELF_UPDATED=1
  export SB_LOCK_INHERIT=1

  local argv
  argv=()
  [ "$ASSUME_YES" = 1 ] && argv+=(-y)
  [ "$QUIET" = 1 ] && argv+=(-q)
  argv+=(--prefix "$PREFIX" update)
  exec "$LAUNCHER" ${argv[@]+"${argv[@]}"}
}

#=======================================================================
# install
#=======================================================================
cmd_install() {
  local src_cfg="" want_ver="" arch="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)  src_cfg="${2:-}"; [ -n "$src_cfg" ] || die "--config 需要参数，如 --config ./config.json"; shift 2 ;;
      --version) want_ver="${2:-}"; [ -n "$want_ver" ] || die "--version 需要参数，如 --version 1.14.0"; shift 2 ;;
      --arch)    arch="${2:-}";    [ -n "$arch" ]    || die "--arch 需要参数：amd64 | arm64"
                 arch_valid "$arch" || die "--arch 取值无效：${arch}（只接受 amd64 | arm64）"; shift 2 ;;
      --force)   force=1; shift ;;
      *) die "install: 未知参数 $1" ;;
    esac
  done

  check_deps
  acquire_lock          # 不弹密码，要尽早防并发

  #--- 0 环境 ---
  step "0/8  环境检查"
  local host_arch; host_arch=$(detect_arch)
  [ -n "$host_arch" ] || die "不支持的 CPU 架构：$(uname -m)"
  [ -n "$arch" ] || arch="$host_arch"
  [ "$arch" = "$host_arch" ] || warn "指定架构 $arch 与本机硬件 $host_arch 不符"
  # 被 Rosetta 翻译时 uname -m 会说 x86_64，而我们按硬件选了 arm64 —— 这两个数
  # 对不上是正常的，但必须说出来，否则用户没法判断这台机器到底装了什么。
  if is_translated; then
    warn "当前 shell 跑在 Rosetta 2 翻译层里（uname -m 报 $(uname -m)，实际硬件是 ${host_arch}）"
    info "按硬件装 darwin-${host_arch}；要原生 shell 的话：arch -arm64 zsh"
  fi
  info "架构：硬件 ${host_arch} → darwin-$arch"
  info "安装前缀：$PREFIX"

  # 配置的静态检查提前到这里：别等下载完内核才发现占位符没替换
  if [ -z "$src_cfg" ]; then
    for c in ./config.json ./sing-box-client-config.json ~/singbox/config.json "$CFG"; do
      [ -f "$c" ] && { src_cfg="$c"; break; }
    done
  fi
  [ -n "$src_cfg" ] || die "未找到配置文件，用 --config <path> 指定"
  [ -f "$src_cfg" ] || die "配置文件不存在：$src_cfg"
  [ -r "$src_cfg" ] || die "配置文件不可读：$src_cfg"
  info "配置：$src_cfg"

  local ph; ph=$(grep -oE 'YOUR_[A-Z_]+|UUID-[AB]' "$src_cfg" 2>/dev/null | sort -u)
  if [ -n "$ph" ]; then
    bad "配置里仍有未替换的占位符："
    printf '%s\n' "$ph" | sed 's/^/        /' >&2
    die "UUID 必须是标准 8-4-4-4-12 格式；替换后重跑"
  fi
  json_valid "$src_cfg" || die "JSON 语法错误：python3 -m json.tool '$src_cfg' 可看具体位置"
  ok "配置：占位符已替换、JSON 语法正确"

  # need_root 排在这之后：上面那几项都是零成本检查，没道理让用户先输一次密码
  # 才被告知「未找到配置文件」。
  need_root

  local need_install=1
  if [ -x "$BIN" ]; then
    info "已安装：$("$BIN" version 2>/dev/null | head -1)"
    if [ "$force" = 1 ]; then need_install=1
    else ask "重新安装内核？" n && need_install=1 || need_install=0
    fi
  fi

  #--- 1 内核 ---
  step "1/8  安装 sing-box 内核"
  if [ "$need_install" = 1 ]; then
    if [ -z "$want_ver" ]; then
      info "查询最新版本…"
      want_ver=$(latest_version) || {
        warn "无法获取版本号（GitHub 与所有镜像均不可达）"
        die "请用 --version <版本号> 手动指定，例如：--version 1.14.0"
      }
    fi
    want_ver="${want_ver#v}"
    info "版本：$want_ver"

    local tmpd tarball url
    tmpd=$(mktmpd)
    tarball="sing-box-${want_ver}-darwin-${arch}.tar.gz"
    url="$GH_DL/v${want_ver}/${tarball}"
    if [ "$DRY" = 0 ]; then
      local want_sha; want_sha=$(asset_digest "$want_ver" "$tarball") || want_sha=""
      if [ -n "$want_sha" ]; then dim "校验值来自 GitHub API：${want_sha}"
      else warn "取不到该 asset 的 sha256（老 release 无 digest 字段，或 API 不可达）—— 本次不做完整性校验"; fi
      download "$tmpd/$tarball" "$url" "内核 v$want_ver" "$want_sha" \
        || die "下载失败（版本号是否正确？）"
      tar xzf "$tmpd/$tarball" -C "$tmpd" || die "解压失败，文件可能不完整"
      local extracted="$tmpd/sing-box-${want_ver}-darwin-${arch}/sing-box"
      [ -f "$extracted" ] || die "压缩包结构异常，未找到 sing-box 可执行文件"
      sudo mkdir -p "$PREFIX/bin"
      # 已有旧版则先备份，便于失败回滚。
      # ⚠️ 不要用 $BIN.prev 当这个临时回滚点：那是 update 留给 rollback 的、
      # 「半小时后才发现问题」时唯一能退回去的一份。之前这里先 cp 覆盖它、
      # 末尾又 rm -f 掉，于是 update 成功后再跑一次 install，rollback 就没东西可退了。
      # 存进 $tmpd（mktmpd 建的，已登记进 TMPFILES 自动回收），既不碰 .prev，
      # 中途崩溃也不会在 /usr/local/bin 留残留。
      local oldbin="$tmpd/sing-box.old"
      [ -x "$BIN" ] && sudo cp "$BIN" "$oldbin"
      sudo install -m 755 "$extracted" "$BIN" || die "安装失败，检查 $PREFIX/bin 写权限"
      sudo xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
      "$BIN" version >/dev/null 2>&1 || {
        [ -f "$oldbin" ] && sudo install -m 755 "$oldbin" "$BIN"
        die "新安装的二进制无法执行，已回滚"
      }
    else
      dim "[dry-run] 下载并安装 $url"
    fi
    ok "已安装到 $BIN"
  else
    info "跳过安装"
  fi

  # 编译标签
  local has_gvisor=1
  if [ "$DRY" = 0 ] && [ -x "$BIN" ]; then
    local vout; vout=$("$BIN" version 2>&1)
    [ "$QUIET" = 1 ] || printf '%s\n' "$vout" | sed 's/^/    /'
    if printf '%s' "$vout" | grep -q with_gvisor; then
      ok "带 with_gvisor，可用 gvisor 协议栈"
    else
      has_gvisor=0
      warn "不带 with_gvisor —— 配置里的 \"stack\": \"gvisor\" 用不了"
    fi
    printf '%s' "$vout" | grep -q with_clash_api \
      && ok "带 with_clash_api，可用 Clash 面板" \
      || dim "不带 with_clash_api，clash_api 配置段会失效"
  fi

  #--- 2 singbox 命令 ---
  step "2/8  安装 singbox 命令"
  info "装到 $LAUNCHER —— 它已经在默认 PATH 里，不必改 ~/.zshrc"
  local self_src
  self_src="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  if _install_launcher "$self_src" "singbox 命令"; then
    [ "$DRY" = 1 ] || ok "已安装到 $LAUNCHER"
    case ":$PATH:" in
      *":$PREFIX/bin:"*) ;;
      *) warn "$PREFIX/bin 不在你的 PATH 里 —— 要用全路径 ${LAUNCHER}，或把该目录加进 PATH" ;;
    esac
  else
    # 装不上不该拖垮整次安装：内核已经就位，用户仍可用仓库副本跑
    warn "singbox 命令没装上 —— 不影响本次安装，之后重跑 install 可再试"
  fi

  #--- 3 系统层 ---
  step "3/8  macOS 系统层准备"
  info "这三项配置文件管不了；不做的话后面验证一定过不去，而症状不指向真正原因。"
  _sysprep

  #--- 4 配置 ---
  step "4/8  放置配置文件"
  # 工作副本，避免直接改用户的源文件
  local work; work=$(mktmp)
  cp "$src_cfg" "$work"

  # cache_file 相对路径
  local cache_rel
  cache_rel=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
p=d.get('experimental',{}).get('cache_file',{}).get('path','')
print('1' if p and not str(p).startswith('/') else '')
" "$work" 2>/dev/null)
  if [ -n "$cache_rel" ]; then
    if ask "cache_file.path 是相对路径（launchd 下工作目录不确定），改为 $ETC/cache.db？" y; then
      python3 - "$work" "$ETC/cache.db" <<'PY'
import json,sys
p,newpath=sys.argv[1],sys.argv[2]
d=json.load(open(p))
cf=d.get("experimental",{}).get("cache_file")
if cf and not str(cf.get("path","")).startswith("/"):
    cf["path"]=newpath
    json.dump(d,open(p,"w"),ensure_ascii=False,indent=2)
    open(p,"a").write("\n")
PY
      ok "已改为绝对路径"
    fi
  fi

  # gvisor 兜底
  if [ "$has_gvisor" = 0 ] && grep -q '"stack"[[:space:]]*:[[:space:]]*"gvisor"' "$work"; then
    if ask "内核不支持 gvisor，把 stack 改成 system？" y; then
      python3 - "$work" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for i in d.get("inbounds",[]):
    if i.get("type")=="tun" and i.get("stack")=="gvisor": i["stack"]="system"
json.dump(d,open(p,"w"),ensure_ascii=False,indent=2); open(p,"a").write("\n")
PY
      ok "已改为 system"
    fi
  fi

  run "sudo mkdir -p '$ETC'"
  if [ -f "$CFG" ] && ! cmp -s "$work" "$CFG"; then
    backup_config >/dev/null || die "备份现有配置失败，未改动 $CFG"
    prune_backups 10
  fi
  run "sudo cp '$work' '$CFG'"
  run "sudo chown root:wheel '$CFG'"
  run "sudo chmod 644 '$CFG'"
  ok "配置已就位：$CFG"

  #--- 5 校验 ---
  step "5/8  静态校验"
  if [ "$DRY" = 0 ]; then
    local chklog; chklog=$(mktmp)
    if sudo "$BIN" check -c "$CFG" >"$chklog" 2>&1; then
      ok "check 通过"
    else
      [ "$QUIET" = 1 ] || sed 's/^/    /' "$chklog" >&2
      grep -qi "rule.set\|rule_set" "$chklog" && \
        info "提示：多为悬空引用 —— dns.rules / route.rules 引用了 route.rule_set 里没定义的 tag"
      die "配置校验未通过，修正后重跑"
    fi
    # 走发现层而不是 grep $chklog：check 对 route.rule_set[].download_detour
    # 一个字都不打（实测 1.14.0），只看 check 输出等于对它全程失明。
    _cfg_audit_notice "$CFG"
  fi

  #--- 6 前台试跑 ---
  step "6/8  前台试跑"
  if [ "$DRY" = 0 ] && ask "前台跑 25 秒，观察规则集下载与 TUN 建立？" y; then
    _stop_all_instances
    local rlog; rlog=$(mktmp)
    # -D 固定工作目录：配置里的相对路径（clash_api 的 external_ui、cache_file 等）
    # 否则会落到你当前所在的目录，留下 ui/ cache.db 这类残留
    sudo mkdir -p "$ETC"
    sudo "$BIN" run -D "$ETC" -c "$CFG" >"$rlog" 2>&1 &
    local rpid=$!
    # 登记给 cleanup：这一跑用的是带 TUN 的真配置，倒计时里按 Ctrl-C 而没人收尸的话，
    # 留下的孤儿会一直占着虚拟网卡和路由表——正是下面那句注释在防的「残留路由」。
    BG_PIDS+=("$rpid")
    local i
    for i in $(seq 25 -1 1); do
      kill -0 "$rpid" 2>/dev/null || break
      [ "$QUIET" = 1 ] || printf "\r    倒计时 %2ds …" "$i"; sleep 1
    done
    [ "$QUIET" = 1 ] || printf "\r%40s\r" " "
    # 温和结束：绝不 kill -9，强杀会留下残留路由
    sudo kill -TERM "$rpid" 2>/dev/null
    local w=0
    while kill -0 "$rpid" 2>/dev/null && [ $w -lt 8 ]; do sleep 1; w=$((w+1)); done
    kill -0 "$rpid" 2>/dev/null && warn "进程未在 8 秒内退出，可能残留路由；必要时重启系统"
    # $rpid 是 sudo 自己的 pid，不是 sing-box 的；判活要以进程名为准复核一遍。
    running && warn "sing-box 仍在前台实例中运行 —— 回那个终端 Ctrl-C，不要 kill -9"
    BG_PIDS=()

    info "启动日志（后 20 行）："
    tail -20 "$rlog" | sed 's/^/      /'
    _diagnose_log "$rlog" && ok "试跑未发现致命问题"
  fi

  #--- 7 服务 ---
  step "7/8  安装 LaunchDaemon"
  _stop_all_instances
  run "sudo launchctl bootout '$LABEL' 2>/dev/null || true"

  if [ "$DRY" = 0 ]; then
    local ptmp; ptmp=$(mktmp)
    cat > "$ptmp" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sing-box</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>run</string>
    <string>-c</string>
    <string>$CFG</string>
  </array>
  <key>WorkingDirectory</key><string>$ETC</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOGFILE</string>
  <key>StandardErrorPath</key><string>$ERRFILE</string>
</dict>
</plist>
PLISTEOF
    plutil -lint "$ptmp" >/dev/null 2>&1 || die "生成的 plist 语法有误（内部错误，请反馈）"
    sudo cp "$ptmp" "$PLIST"
    sudo chown root:wheel "$PLIST"
    sudo chmod 644 "$PLIST"
    ok "plist 已写入并通过语法检查"

    sudo launchctl enable "$LABEL" 2>/dev/null || true
    if ! sudo launchctl bootstrap system "$PLIST" 2>&1 | sed 's/^/    /'; then
      bad "服务加载失败"
      info "跑 $(basename "$0") doctor 收集诊断"
      exit 1
    fi
    sleep 3
    if running; then ok "服务已启动并设为开机自启"
    else
      bad "服务未起来"
      sudo tail -20 "$ERRFILE" 2>/dev/null | sed 's/^/      /'
      exit 1
    fi
  fi

  #--- 8 验证 ---
  step "8/8  验证"
  # install 的退出码保持 0：验证没过不等于安装没成。但也不能让「安装完成」这句
  # 全绿的口吻盖过上面刚打的那一堆 ✗ —— 按 verify 的两档结果分叉措辞。
  local vrc=0
  [ "$DRY" = 0 ] && { cmd_verify || vrc=$?; }

  echo
  case "$vrc" in
    0) printf '%s安装完成。%s\n' "$C_B" "$C_N" ;;
    1) printf '%s安装完成，但验证的链路档没过（见上面的 ✗）。%s\n' "$C_B" "$C_N"
       info "节点参数或链路的问题，配置改不了服务端；先按 verify 第 1、2 步的提示查" ;;
    *) printf '%s安装完成，但验证的策略档没过（见上面的 ✗）。%s\n' "$C_B" "$C_N"
       info "路由策略或环境的问题；跑 rules 与 debug 看规则命中" ;;
  esac
  info "日常管理：$(basename "$0") {status|verify|syscheck|restart|logs|rules|doctor}"
  warn "还有两件事要自己做："
  info "  1. 关闭浏览器内置 DoH（Chrome: chrome://settings/security）"
  info "  2. 跑 $(basename "$0") rules 验证规则集 URL —— 下载失败只会静默让规则不命中"
}

#=======================================================================
# 系统层准备（install 内部调用，也可单独 sysprep）
#=======================================================================
_sysprep() {
  local svcs; svcs=$(network_services)
  [ -n "$svcs" ] || { warn "未获取到网络服务列表"; return 1; }

  # --- IPv6 ---
  echo
  info "${C_B}2.1 关闭 IPv6${C_N}"
  dim "TUN 只接管 IPv4；未关的 IPv6 会绕过全部路由规则直连"
  while IFS= read -r svc; do
    local v6; v6=$(networksetup -getinfo "$svc" 2>/dev/null | awk -F': ' '/^IPv6:/{print $2}')
    printf '      %-28s IPv6=%s\n' "$svc" "${v6:-?}"
  done <<< "$svcs"
  if ask "对所有网络服务关闭 IPv6？" y; then
    while IFS= read -r svc; do
      run "sudo networksetup -setv6off \"$svc\" 2>/dev/null || true"
    done <<< "$svcs"
    ok "已关闭（按服务生效，新增网络服务需重跑 sysprep）"
    dim "Thunderbolt Bridge 若用于 Mac 互联：sudo networksetup -setv6automatic \"Thunderbolt Bridge\""
  fi

  # --- DNS ---
  echo
  info "${C_B}2.2 系统 DNS 指向非局域网地址${C_N}"
  dim "DNS 若是路由器地址，查询不进 TUN，明文出网被投毒（典型：google.com → 157.240.x.x）"
  local need_dns=0
  while IFS= read -r svc; do
    local d; d=$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ')
    printf '      %-28s DNS=%s\n' "$svc" "$d"
    is_private_dns "$d" && need_dns=1
  done <<< "$svcs"
  if [ "$need_dns" = 1 ]; then warn "有服务的 DNS 是内网地址或未设置"; fi
  if ask "把所有服务的 DNS 设为 ${PROXY_DNS}？（反正会被内核劫持，只需保证不是内网地址）" y; then
    # 只在没有备份时记一次。sysprep 的定位就是「换网络、插网卡后重跑」，
    # 而那时 DNS 多半已经是 $PROXY_DNS 了——无条件重记会把当初那份真正的原值
    # （比如内网 Pi-hole 地址）按 empty 覆盖掉，再也还原不回去。
    # 判据与 cmd_start / cmd_dns proxy 保持一致。
    [ -f "$DNS_BACKUP" ] || dns_backup_save
    dns_apply_proxy
    ok "已设置并清空 DNS 缓存"
    dim "stop / disable / uninstall 时可一键还原"
  fi

  # --- 冲突客户端 ---
  echo
  info "${C_B}2.3 检查其他 VPN 客户端${C_N}"
  local conflict
  conflict=$(ps -axo comm= 2>/dev/null | grep -Ei "tailscaled?$|clash|mihomo|surge|openvpn|wireguard|warp-svc|nordvpn|expressvpn" | sort -u)
  if [ -n "$conflict" ]; then
    warn "检测到可能抢占 utun 的进程："
    printf '%s\n' "$conflict" | sed 's/^/        /' >&2
    info "请用各客户端自己的方式退出，别用 kill -9（会留下残留路由）"
    ask "已处理，继续？" y || die "已中止"
  else
    ok "未发现冲突进程"
  fi
  local nc; nc=$(scutil --nc list 2>/dev/null | grep -c "^\* (Connected)" || true)
  [ "${nc:-0}" -gt 0 ] && warn "系统设置里有已连接的 VPN：scutil --nc stop \"<名称>\""

  echo
  dim "2.4 浏览器内置 DoH 需手动关闭（脚本改不了）："
  dim "    Chrome  chrome://settings/security → 关闭「使用安全 DNS」"
  dim "    Firefox about:config → network.trr.mode = 5"
  return 0
}

cmd_sysprep() { check_deps; need_root; step "系统层准备"; _sysprep; }

#=======================================================================
# 内部工具
#=======================================================================
# 停掉所有 sing-box 实例（服务 + 前台），绝不 kill -9
_stop_all_instances() {
  [ "$DRY" = 1 ] && return 0
  daemon_loaded && { sudo launchctl bootout "$LABEL" 2>/dev/null; sleep 1; }
  if running; then
    info "停止残留的 sing-box 进程…"
    sudo pkill -TERM -x sing-box 2>/dev/null
    local w=0
    while running && [ $w -lt 8 ]; do sleep 1; w=$((w+1)); done
    running && warn "进程仍在运行；不使用 kill -9（会留下残留路由），请手动检查"
  fi
  return 0
}

# 判读日志，返回 0=无致命问题
_diagnose_log() {
  local f="$1" fatal=0
  grep -qi "operation not permitted" "$f" && { bad "权限不足：必须 root；服务须是 LaunchDaemon 而非 LaunchAgent"; fatal=1; }
  grep -qi "address already in use" "$f" && {
    bad "端口被占用"
    local s; s=$(sock_addr); local p="${s##*:}"
    sudo lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | sed 's/^/        /' >&2
    info "常见占用者：别的代理客户端；先退出它"
    fatal=1
  }
  grep -qi "unsupported.*stack\|gvisor" "$f" && grep -qi "not built\|unsupported" "$f" && {
    bad "协议栈不受支持：内核可能不带 with_gvisor，把配置里 stack 改成 system"; fatal=1; }
  # ⚠️ 别写成 `grep -c … || echo 0`：grep -c 无匹配时**已经打印了 0** 并返回 1，
  # 那个 || 会再追加一个，nf 变成 "0\n0"，后面的 [ -gt ] 直接把
  # `[: 0\n0: integer expression expected` 打到用户终端——而且只在日志干净时发生。
  local nf; nf=$(grep -ci "failed to download rule.set\|rule.set.*fail" "$f" 2>/dev/null); nf="${nf:-0}"
  if [ "${nf:-0}" -gt 0 ]; then
    warn "有规则集下载失败 —— 不阻止启动，但那些规则永远不命中"
    grep -i "rule.set" "$f" | grep -i fail | head -8 | sed 's/^/        /' >&2
    info "跑 $(basename "$0") rules 逐个验证 URL"
  fi
  return $fatal
}

#=======================================================================
# status
#=======================================================================
cmd_status() {
  require_installed
  # status 从不 need_root，但 daemon_loaded 与下面的 lsof 都要 sudo。
  # 没有票据时：daemon_loaded 的密码提示被 2>&1 吞掉 → 终端无提示卡住；
  # 非交互下 sudo 直接失败 → 明明在跑的服务被渲染成「LaunchDaemon 未加载」。
  # 先无交互探一次，探不到就明说跳过，不要把「不知道」说成「没有」。
  local can_sudo=1
  sudo -n true 2>/dev/null || can_sudo=0
  step "服务状态"
  info "内核：$("$BIN" version 2>/dev/null | head -1)"
  if running; then ok "sing-box 运行中（PID $(pgrep -x sing-box | tr '\n' ' '))"
  else bad "sing-box 未运行"; fi
  if [ "$can_sudo" = 0 ]; then
    warn "无 sudo 票据，跳过 LaunchDaemon 与监听端口检查（先跑一次 sudo -v 再来）"
  elif daemon_loaded; then ok "LaunchDaemon 已加载"
  else warn "LaunchDaemon 未加载（当前可能是前台运行）"; fi
  [ -f "$PLIST" ] && ok "开机自启已配置" || warn "未安装 plist，重启后不会自动运行"

  step "TUN 与路由"
  local ifn
  ifn=$(python3 -c "
import json
try:
    d=json.load(open('$CFG'))
    for i in d.get('inbounds',[]):
        if i.get('type')=='tun': print(i.get('interface_name','')); break
except Exception: pass" 2>/dev/null)
  if [ -n "$ifn" ]; then
    ifconfig "$ifn" >/dev/null 2>&1 && ok "$ifn 已建立" || warn "未见 $ifn"
  else
    ifconfig 2>/dev/null | grep -q utun && ok "存在 utun 接口" || warn "未见 utun 接口"
  fi
  _tun_route_lines | sed 's/^/      /'
  local rstate; rstate=$(_tun_route_state)
  if [ "$rstate" = full ]; then
    ok "路由已指向 utun"
    dim "指向 en0 的那条 default 必须保留 —— 内核出站流量要靠它"
  else
    bad "$(_tun_route_msg "$rstate")，跑 doctor"
  fi

  step "监听端口"
  local pid; pid=$(pgrep -x sing-box | head -1)
  if [ "$can_sudo" = 0 ]; then
    dim "（无 sudo 票据，跳过）"
  elif [ -n "$pid" ]; then
    sudo lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null \
      | awk 'NR>1{printf "      %-26s %s\n",$9,$1}' || true
    sudo lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null | grep -q '\*:' \
      && warn "存在 *: 监听 —— 局域网可访问，应把 listen 改回 127.0.0.1"
  else
    dim "（进程未运行）"
  fi

  # 日志体积。这一段不需要 sudo（文件是 0644），所以放在 can_sudo 判断之外。
  # launchd 把 stdout/stderr 直接怼进文件，只涨不落，涨到几百 MB 也不会自己冒出来。
  step "日志体积"
  local ltotal; ltotal=$(log_total_bytes)
  printf '      %-34s %s\n' "$LOGFILE + $(basename "$ERRFILE")" "$(human_size "$ltotal")"
  log_size_warn || dim "未超过 ${LOG_WARN_MB} MB 的告警阈值"
}

#=======================================================================
# syscheck
#=======================================================================
# IPv6 地址分两筐看。syscheck / verify 要抓的是**能出公网**的地址——运营商分下来的
# 2000::/3，那才是绕开代理的漏洞。fc00::/7（ULA，实际都是 fd 开头）在公网上不可路由，
# 而 macOS 上最常见的来源是点对点隧道自己配的内网段：Xcode 的 CoreDevice 设备隧道
# （utunN，mtu 16000，fdxx::2 对 fdxx::1）、Thunderbolt 直连、Docker/OrbStack 的
# 虚拟网卡。把它们当「全局 IPv6」报 ✗，用户关不掉、也不该关——2026-09-12 真机上
# 插着 iPhone 跑 xcodebuild 时就被这样误报过。
# fe80::（链路本地）与 ::1（环回）照旧不算——但要钉在地址开头：旧写法 grep -v '::1 '
# 会把 2409:...::1 这种以 ::1 结尾的公网地址一并滤掉（路由器/静态分配最爱这么配），
# 真泄漏反而报绿。
_sb_v6_lines() { ifconfig 2>/dev/null | grep inet6 | grep -v -E 'inet6 (fe80:|::1 )'; }
_sb_v6_global() { _sb_v6_lines | grep -v -E 'inet6 f[cd][0-9a-f]{2}:'; }
_sb_v6_ula()    { _sb_v6_lines | grep -E 'inet6 f[cd][0-9a-f]{2}:'; }
# 有 ULA 时提一句，让用户知道它被看见了、也知道为什么不算
_sb_v6_ula_note() {
  local ula; ula=$(_sb_v6_ula)
  [ -n "$ula" ] || return 0
  [ "$QUIET" = 1 ] && return 0
  dim "另有 ULA（fd00::/8）地址，公网不可路由、不算泄漏——多半是 Xcode 设备隧道或虚拟网卡："
  printf '%s\n' "$ula" | sed 's/^[[:space:]]*/        /'
}

cmd_syscheck() {
  step "系统层复查"
  dim "IPv6 与 DNS 按网络服务生效、不会继承 —— 换网络、插网卡、VPN 退出没还原都会留缺口"
  echo
  printf '      %-28s %-6s %s\n' "网络服务" "IPv6" "DNS"
  printf '      %-28s %-6s %s\n' "------" "----" "---"
  local bad_count=0 svcs
  svcs=$(network_services) || { bad "无法获取网络服务列表"; return 1; }
  while IFS= read -r svc; do
    local v6 dns flag=""
    v6=$(networksetup -getinfo "$svc" 2>/dev/null | awk -F': ' '/^IPv6:/{print $2}')
    dns=$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ')
    [ "$v6" != "Off" ] && { flag="← IPv6 未关"; bad_count=$((bad_count+1)); }
    if is_private_dns "$dns"; then flag="$flag ← DNS 为内网/未设"; bad_count=$((bad_count+1)); fi
    printf '      %-28s %-6s %s %s\n' "$svc" "${v6:-?}" "${dns:-none}" "$flag"
  done <<< "$svcs"
  echo
  [ "$bad_count" = 0 ] && ok "所有服务：IPv6 已关、DNS 非内网" \
    || warn "$bad_count 项不合格 —— 跑 $(basename "$0") sysprep 修复"

  step "IPv6 实际状态"
  local v6addr
  v6addr=$(_sb_v6_global)
  if [ -z "$v6addr" ]; then
    ok "无全局 IPv6 地址"
    dim "fe80::（链路本地）与 ::1（环回）属正常，关不掉也不该关"
  else
    bad "仍有全局 IPv6 地址："
    printf '%s\n' "$v6addr" | sed 's/^[[:space:]]*/        /' >&2
    bad_count=$((bad_count+1))
  fi
  _sb_v6_ula_note

  # 同 cmd_rules：不返回结果的话，自动化只能靠抓输出。
  [ "$bad_count" = 0 ] && return 0
  return 1
}

#=======================================================================
# verify
#=======================================================================

# 解析一个域名的 A 记录，四级降级：dig → host → dscacheutil → python3。
# 任一级拿到结果就采用；四级全废才返回 1。
#
# 原实现只认 dig 一个，`command -v dig` 一 miss 就把整步 dim 跳过——而 dig 是
# macOS 自带的 /usr/bin/dig，同目录还躺着 host / dscacheutil，脚本本身又硬依赖
# python3。根本不缺解析手段，缺的是去用它们。
#
# ⚠️ 四级全废是「本机没有可用解析手段」，跟「解析到了但结果可疑」是两回事，
# 调用方必须分开报——把前者也说成污染，会把人送去查一个根本没坏的 DNS。
# ⚠️ dscacheutil 查不到时也是 exit 0 + 空输出，所以每一级都只看输出、不看退出码。
#
# SB_FAKE_PY_RESOLVE_FAIL 只服务于测试：第 4 级是内联 python3，PATH 桩拦不住它，
# 联网机器上它总会成功，「四级全废」那条断言就永远是假绿。
_sb_resolve_a() {
  local name="$1" out
  out=$(dig +short +time=3 +tries=1 "$name" 2>/dev/null \
        | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | head -3)
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  out=$(host -W 3 "$name" 2>/dev/null | awk '/has address/ {print $NF}' | head -3)
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  out=$(dscacheutil -q host -a name "$name" 2>/dev/null | awk '/^ip_address:/ {print $2}' | head -3)
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  if [ "${SB_FAKE_PY_RESOLVE_FAIL:-}" != 1 ]; then
    out=$(python3 - "$name" <<'PY' 2>/dev/null
import socket, sys
try:
    print("\n".join(sorted({i[4][0] for i in socket.getaddrinfo(sys.argv[1], 80, socket.AF_INET)})[:3]))
except Exception:
    pass
PY
)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  return 1
}

# QUIC 是否还通得出去。返回 0 = 通（禁 QUIC 规则没生效，该报失败），1 = 已阻断。
#
# 不再走 `curl --http3`：本机 curl 8.7.1 是 SecureTransport 版，压根没编 HTTP/3，
# 那半步从来没有真跑过，只是每次都 dim 一行「跳过」。改为自己发包——
# 构造一个 version=0x1a2a3a4a（RFC 9000 §15 的保留版本，永远不会被真正支持）的
# long-header Initial 包，填到 1200 字节发过去；按 RFC 9000 §6，服务端收到不认识的
# 版本**必须**回一个 Version Negotiation 包（version 字段为 0x00000000）。
# 收到回包 = UDP/443 出得去 = QUIC 没被挡住。
#
# 两个端点任一收到回包就算通。它们都不在任何路由规则里，加备胎不动配置。
#
# 全部超时时，「已阻断」与「本机 UDP 整体出不去」曾经区分不了，一律按前者
# 乐观读法判——于是拔了网线也会打 ok「QUIC 已阻断」。现在由 _sb_udp_alive 这个
# 对照端点来分辨，见 cmd_verify 第 4 步。
# 没有改成「多试几次」：QUIC 被挡住是**期望的成功路径**，而它的表现恰恰是全部超时，
# 加重试等于给每一次正常的 verify 平白加十几秒，还要乘 _sb_verify_rounds 的两轮。
#
# SB_FAKE_QUIC 只服务于测试：探测是内联 python3，PATH 桩拦不住它，没有这个后门
# 第 4 步就没法在离线的测试里驱动。
# UDP 到底通不通的对照组。发一个标准 DNS 查询到公共解析器的 udp/53，收到应答即算通。
# 返回 0 = UDP 有来回，1 = 没有。
#
# ⚠️ 它证明的是「UDP 有来回」，不是「UDP 直出」：配置里的 DNS 劫持规则完全可能
# 把这个查询接管掉再代答。用作「本机 UDP 是不是整个废了」的判据够用，别当成别的。
# SB_FAKE_UDP 与 SB_FAKE_QUIC 同理，只为离线测试留的注入点。
_sb_udp_alive() {
  case "${SB_FAKE_UDP:-}" in
    alive) return 0 ;;
    dead)  return 1 ;;
  esac
  python3 - <<'PY' >/dev/null 2>&1
import os, socket, struct, sys

TARGETS = [("1.1.1.1", 53), ("8.8.8.8", 53)]

# 最小 DNS 查询：example.com A IN
def query(host, port):
    tid = os.urandom(2)
    pkt = tid + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for label in (b"example", b"com"):
        pkt += bytes([len(label)]) + label
    pkt += b"\x00\x00\x01\x00\x01"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(pkt, (host, port))
        data, _ = s.recvfrom(2048)
    except Exception:
        return False
    finally:
        s.close()
    return len(data) >= 2 and data[:2] == tid

sys.exit(0 if any(query(h, p) for h, p in TARGETS) else 1)
PY
}

_sb_quic_open() {
  case "${SB_FAKE_QUIC:-}" in
    open)    return 0 ;;
    blocked) return 1 ;;
  esac
  python3 - <<'PY' >/dev/null 2>&1
import os, socket, struct, sys

TARGETS = [("cloudflare-quic.com", 443), ("quic.rocks", 4433)]

def probe(host, port):
    dcid, scid = os.urandom(8), os.urandom(8)
    pkt = b"\xc0" + struct.pack(">I", 0x1a2a3a4a) \
        + bytes([len(dcid)]) + dcid + bytes([len(scid)]) + scid + b"\x00"
    pkt += b"\x00" * (1200 - len(pkt))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(pkt, (host, port))
        data, _ = s.recvfrom(2048)
    except Exception:
        return False
    finally:
        s.close()
    # 版本协商包：long header 标志位 + version 字段全 0
    return len(data) >= 5 and bool(data[0] & 0x80) and data[1:5] == b"\x00\x00\x00\x00"

sys.exit(0 if any(probe(h, p) for h, p in TARGETS) else 1)
PY
}

# 取「从国内直连出去」的公网 IP，输出 `<ip>|<一句话归属>`。全挂才返回 1。
# cip.cc 一家抽风不该让整步没有结论，所以配两个备胎逐个试；三家的输出格式各不
# 相同，统一用正则抽第一个 IPv4。
_sb_fetch_cn_ip() {
  local u body ip
  for u in https://cip.cc https://myip.ipip.net http://ip.3322.net; do
    body=$(curl -s --max-time 8 "$u" 2>/dev/null)
    ip=$(printf '%s' "$body" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [ -n "$ip" ]; then
      # 归属信息按**行**取前 3 行（cip.cc 是 IP / 地址 / 运营商，后面还有数据二、
      # 数据三、URL 几行没用的）。按字符硬截会断在字段中间，打出来像坏了。
      # 制表符也要一起挤掉——cip.cc 用的是 `IP<TAB>: ...`。
      local desc
      desc=$(printf '%s' "$body" | head -3 | tr '\n' ' ' \
             | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
      # 备胎或异常响应可能是很长的一行，留个上限防刷屏；真截了就明说。
      [ ${#desc} -gt 100 ] && desc="$(printf '%s' "$desc" | cut -c1-100)…"
      printf '%s|%s' "$ip" "$desc"
      return 0
    fi
  done
  return 1
}

cmd_verify() {
  require_installed
  VERIFY_BAD=0
  VERIFY_POLICY_BAD=0
  running || { bad "服务未运行 —— 先 $(basename "$0") start"; return 1; }
  local s; s=$(sock_addr)

  step "1/6  节点链路（绕开 TUN）"
  local ip_socks
  ip_socks=$(curl -s --max-time 12 -x "socks5h://$s" https://api.ipify.org 2>/dev/null)
  if [ -n "$ip_socks" ]; then
    ok "SOCKS 出口：$ip_socks"
  else
    bad "SOCKS 不通 —— 问题在节点参数（uuid / SNI / public_key / short_id / flow / Mux）"
    info "与 TUN、路由规则无关；这一步不过，后面的结果都没有参考价值"
    return 1
  fi

  step "2/6  出口 IP 分流"
  local ip_main ip_soc org i
  ip_main=$(curl -s --max-time 12 https://api.ipify.org 2>/dev/null)
  # ipinfo.io 不换域名——它被写死在配置的 vpsre 社交组里，是分流判定的固定参照物，
  # 换端点等于改配置。抽风就同一个端点多试两次。
  # ⚠️ 跳出条件必须看**解析出来的 ip_soc**，不能看响应体非空。限流页、502、
  # Cloudflare 拦截页都是「非空但不是 JSON」，`curl -s` 照样退 0 —— 拿响应体当
  # 判据就会只试 1 次就落到下面的硬失败，还打一句「连取 3 次」的假话。
  local soc_json=""
  ip_soc=""
  for i in 1 2 3; do
    soc_json=$(curl -s --max-time 15 https://ipinfo.io/json 2>/dev/null)
    ip_soc=$(printf '%s' "$soc_json" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("ip",""))
except Exception: print("")' 2>/dev/null)
    [ -n "$ip_soc" ] && break
    [ "$i" = 3 ] || sleep 2
  done
  org=$(printf '%s' "$soc_json" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("org",""))
except Exception: print("")' 2>/dev/null)
  info "兜底出站   ：${ip_main:-取不到}        （应为 vpstrans 机房 IP）"
  info "社交组出站 ：${ip_soc:-取不到}  ${org}  （应为 vpsre 住宅 IP）"
  if [ -z "$ip_main" ]; then
    vbad "兜底取不到 IP —— 跑 status 看 TUN 是否接管"
  elif [ -z "$ip_soc" ]; then
    # 连试 3 次还是空，就不能再当软告警放过去——「分流没生效」和「参照物挂了」
    # 得有个结论。计策略档：第三方站点可用性不是内核问题，回滚换不回来。
    vpbad "ipinfo.io 连取 3 次都没结果 —— 分流判断做不了，这一步没有结论"
  elif [ "$ip_main" = "$ip_soc" ]; then
    vbad "两个出口相同 —— 服务端按 UUID 分流未生效，或 vpsre 中转链路断了"
    info "这是服务端问题，客户端配置改不了"
    dim "也可能是 ipinfo.io 没命中社交规则集；用 debug 确认它走的是哪个出站"
  else
    ok "两个出口不同，UUID 分流生效"
    dim "确认上面的 org 是住宅运营商而非机房"
  fi

  step "3/6  DNS 防泄漏"
  local g
  if g=$(_sb_resolve_a www.google.com); then
    g=$(printf '%s' "$g" | tr '\n' ' ')
    info "google.com → ${g}"
    # ⚠️ 必须逐条 IP 比，而且必须保持前缀锚定。
    #   拿整行比：_sb_resolve_a 最多回 3 条，污染地址不在第一条就漏检
    #             （实测 "1.2.3.4 157.240.9.9 5.6.7.8" 会被判成「解析正常」）。
    #   改成 *31.13.* 这种通配：131.13.5.5 会被当成污染（子串命中），是误报。
    local one polluted=0
    for one in $g; do
      case "$one" in 157.240.*|31.13.*) polluted=1 ;; esac
    done
    if [ "$polluted" = 1 ]; then
      vpbad "解析结果异常（疑似污染）—— 跑 syscheck 看系统 DNS 是不是内网地址"
    else
      ok "解析正常"
    fi
  else
    vpbad "dig / host / dscacheutil / python3 四级都拿不到 A 记录 —— 本机没有可用解析手段"
    info "解析结果没有可疑之处可言 —— 是解析这件事本身做不了；先确认能上网，再看 syscheck"
  fi
  dim "浏览器验证：dnsleaktest.com 的 Extended Test 不应出现本地运营商"

  step "4/6  IPv6 与 QUIC"
  local v6; v6=$(_sb_v6_global)
  [ -z "$v6" ] && ok "无全局 IPv6" || vbad "存在全局 IPv6 —— 跑 syscheck"
  _sb_v6_ula_note
  if _sb_quic_open; then
    vpbad "QUIC 未被阻断 —— 对端回了版本协商包，UDP/443 出得去"
    info "检查禁 QUIC 规则（udp + 443 + reject）是否在规则表里、是否排在放行规则之前"
  elif _sb_udp_alive; then
    ok "QUIC 已阻断"
  else
    # 对照端点也不通 = 本机 UDP 整体出不去，那么「QUIC 探测超时」什么也证明不了。
    # 按第 3、5 步一样的判据处理：取不到数据就是没有结论，不许拿 ok 混过去。
    vpbad "UDP 整体出不去（对照端点 udp/53 也没有应答）—— QUIC 这一步没有结论"
    info "先确认能上网；断网或 UDP 被全阻时，「已阻断」和「测不了」长得一模一样"
  fi

  step "5/6  国内直连与局域网"
  local cn cn_ip cn_desc
  if cn=$(_sb_fetch_cn_ip); then
    cn_ip="${cn%%|*}"; cn_desc="${cn#*|}"
    info "国内直连出口：${cn_ip}  ${cn_desc}"
    # 国内出口等于第 1 步的 SOCKS 出口 = 国内流量全被代理接走了，直连规则没生效。
    # 只跟 SOCKS 出口比，不跟兜底/社交出口比：那两个的故障形态另有判据。
    if [ "$cn_ip" = "$ip_socks" ]; then
      vpbad "国内直连出口与 SOCKS 出口相同（${cn_ip}）—— 国内流量全走了代理"
      info "检查 geosite-cn / geoip-cn 规则是否排在兜底出站之前"
    else
      ok "国内直连生效，出口与代理出口不同"
    fi
  else
    vpbad "cip.cc 与两个备胎都取不到国内出口 IP —— 这一步没有结论"
  fi
  local gw; gw=$(netstat -rn -f inet 2>/dev/null | awk '/^default/ && $6!~/utun/ {print $2; exit}')
  if [ -z "$gw" ]; then
    vpbad "取不到默认网关 —— 局域网可达性无从判断"
    info "跑 status 看路由表；TUN 抢走了默认路由而没留物理网关，局域网设备会全部失联"
  else
    # 连试 3 次才判失败：无线抖一下丢一个包，不该把一次好端端的升级判成坏的。
    local p ping_ok=0
    for p in 1 2 3; do
      if ping -c1 -W1500 "$gw" >/dev/null 2>&1; then ping_ok=1; break; fi
    done
    if [ "$ping_ok" = 1 ]; then
      ok "局域网网关 $gw 可达"
    else
      vpbad "网关 $gw 连试 3 次都不通 —— 检查私有网段规则是否排在最前"
    fi
  fi

  #--- 6 配置现代性 -------------------------------------------------------
  step "6/6  配置现代性"
  # 挂**策略档**而不是链路档：废弃字段不会让链路断，回滚内核也换不回来 ——
  # 它是「将来会坏」，不是「现在就坏」。这跟 _sb_verify_rounds 的取舍一致：
  # 返回 2 不触发回滚，返回 1 才触发。判成链路档会让一次好端端的升级被回滚掉。
  local audit_rows; audit_rows=$(mktmp)
  if ! _cfg_audit "$CFG" >"$audit_rows" 2>/dev/null; then
    # 审不了 ≠ 有问题。判成 vpbad 会让一次干净的 verify 退 2，而 update 的
    # 阶段 3 读的正是这个退出码。
    info "配置现代性：这次没审成（读不到 ${CFG}，或内核跑不起来），跳过"
  else
  local n_audit; n_audit=$(awk -F'\t' '$1=="removed"||$1=="deprecated"{n++} END{print n+0}' "$audit_rows")
  if [ "${n_audit:-0}" = 0 ]; then
    ok "配置里没有废弃字段，也没有未知键"
  else
    vpbad "配置里有 ${n_audit} 处废弃/未知字段 —— 跑 $(basename "$0") config audit"
    grep -vE '^(notice|dropped)' "$audit_rows" | cut -f1-4 | sed 's/^/        /' | cut -c1-160 >&2
  fi
  fi

  # 退出码要如实反映六步的结果，并且要能分辨「回滚有用」和「回滚白搭」：
  #   0 全过 / 1 链路档失败（该回滚）/ 2 仅策略档失败（不该回滚）
  # 两档都失败时报 1，链路优先——链路都断了，策略上的结论没有参考价值。
  [ "$VERIFY_BAD" -gt 0 ] && return 1
  [ "$VERIFY_POLICY_BAD" -gt 0 ] && return 2
  return 0
}

#=======================================================================
# rules
#=======================================================================
cmd_rules() {
  require_installed
  step "验证规则集 URL"
  dim "下载失败不阻止启动，只静默让规则永不命中 —— 最隐蔽的一类故障"
  echo
  local proxy=""
  running && proxy="-x socks5h://$(sock_addr)"
  local list; list=$(python3 -c "
import json
try:
    d=json.load(open('$CFG'))
    for r in d.get('route',{}).get('rule_set',[]):
        if r.get('type')=='remote' and r.get('url'):
            print(r['tag'], r['url'])
except Exception: pass" 2>/dev/null)
  if [ -z "$list" ]; then info "配置中没有 remote 规则集"; return 0; fi

  local fail=0 total=0
  while read -r tag url; do
    [ -n "$tag" ] || continue
    total=$((total+1))
    local code
    code=$(curl -s $proxy -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null)
    if [ "$code" = 200 ]; then
      printf '%s  ✓%s %-30s 200\n' "$C_OK" "$C_N" "$tag"
    else
      printf '%s  ✗ %-30s %s%s\n' "$C_ERR" "$tag" "${code:-timeout}" "$C_N"
      fail=$((fail+1))
    fi
  done <<< "$list"
  echo
  if [ "$fail" -gt 0 ]; then
    warn "$fail/$total 个规则集不可达"
    dim "404 多为分类名不对：x 可能叫 twitter、meta 可能叫 facebook、apple@cn 与 apple-cn 写法不一"
    dim "全部超时则多半是代理未运行或出站不通"
  else
    ok "全部 $total 个规则集可达"
  fi

  step "缓存状态"
  if [ -f "$ETC/cache.db" ]; then
    ls -lh "$ETC/cache.db" | awk '{printf "      %s  %s %s %s\n",$5,$6,$7,$8}'
    dim "有几 MB 且时间较新，说明规则集确实下下来了"
  else
    warn "无 cache.db —— 规则集可能一次都没下成功"
  fi

  # 退出码要能被自动化读：之前最后一条语句是 warn（printf），恒返回 0，
  # 于是「全部不可达」和「全部可达」在脚本外看起来一模一样。
  [ "$fail" -gt 0 ] && return 1
  return 0
}

#=======================================================================
# debug
#=======================================================================
cmd_debug() {
  require_installed
  need_root
  # _stop_all_instances 自己认 $DRY，但下面那条 sudo "$BIN" run 不认 ——
  # 不在这里早退的话，-n debug 会真的把内核跑到前台。
  [ "$DRY" = 1 ] && { dim "[dry-run] 停掉服务，以 log.level=debug 前台跑 ${BIN}，Ctrl-C 后恢复服务"; return 0; }
  acquire_lock
  step "debug 前台试跑"
  info "停掉服务、以 debug 级别前台运行。方括号里的出站 tag 就是路由结果。"
  info "Ctrl-C 结束后自动恢复服务。"
  echo

  local tmpcfg; tmpcfg=$(mktmp_named "config-debug.json")
  python3 - "$CFG" "$tmpcfg" <<'PY' || die "生成临时配置失败"
import json,sys
d=json.load(open(sys.argv[1]))
d.setdefault("log",{})["level"]="debug"
json.dump(d,open(sys.argv[2],"w"),ensure_ascii=False,indent=2)
PY

  # 必须是全局变量：trap 在函数返回后才触发，那时 local 作用域已销毁
  DEBUG_WAS_LOADED=0
  daemon_loaded && DEBUG_WAS_LOADED=1
  # ⚠️ trap 必须抢在 _stop_all_instances 前面接管：那一步内部有 sleep 1 加
  # 最多 8 次 sleep 1，能阻塞近 9 秒，而它已经把现网服务 bootout 掉了。
  # 之前 trap 注册在它之后，这几秒里按 Ctrl-C 只会走顶层那个仅清理临时文件的
  # cleanup，服务再也不会被拉起来——正好和上面那句「Ctrl-C 结束后自动恢复服务」相反。
  # 必须在 DEBUG_WAS_LOADED 赋值之后，否则 _debug_restore 读到 0 会跳过恢复。
  trap '_debug_restore; cleanup' EXIT INT TERM
  _stop_all_instances
  sudo mkdir -p "$ETC"
  sudo "$BIN" run -D "$ETC" -c "$tmpcfg"
  # 正常退出（内核自己结束）时也要恢复；trap 会再调一次，_debug_restore 幂等
  _debug_restore
}

# 恢复 debug 前的服务状态。可能被 trap 多次调用，做成幂等。
_debug_restore() {
  [ "${DEBUG_RESTORED:-0}" = 1 ] && return 0
  DEBUG_RESTORED=1
  echo
  if [ "${DEBUG_WAS_LOADED:-0}" = 1 ]; then
    if daemon_loaded; then
      ok "服务仍在运行"
    elif sudo launchctl bootstrap system "$PLIST" 2>/dev/null; then
      sleep 2
      running && ok "服务已恢复" || warn "服务已加载但进程未出现 —— 查 $(basename "$0") status"
    else
      warn "服务恢复失败 —— 手动跑 $(basename "$0") start"
    fi
  else
    dim "debug 之前服务本就未加载，不做恢复"
  fi
  return 0
}

#=======================================================================
# edit / config
#=======================================================================
cmd_edit() {
  local want_ed="" save_ed=1 show_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --editor)       want_ed="${2:-}"; [ -n "$want_ed" ] || die "--editor 需要参数，如 --editor nano"; shift 2 ;;
      --once)         save_ed=0; shift ;;
      --show-editor)  show_only=1; shift ;;
      --reset-editor) prefs_unset editor; ok "已清除编辑器偏好，回到 \$EDITOR / $DEFAULT_EDITOR"; return 0 ;;
      *) die "edit: 未知参数 $1（--editor <cmd> | --once | --show-editor | --reset-editor）" ;;
    esac
  done

  if [ "$show_only" = 1 ]; then
    local saved; saved=$(prefs_get editor) || saved=""
    info "已保存偏好：${saved:-（无）}"
    info "环境变量 EDITOR：${EDITOR:-（未设）}"
    info "本次将使用：$(resolve_editor || echo '（无可用编辑器）')"
    return 0
  fi

  require_installed
  need_root
  acquire_lock

  local ed
  ed=$(resolve_editor "$want_ed") || die "找不到任何可用编辑器（试试 --editor nano）"
  info "编辑器：$ed"

  # 只有显式指定且确实可用时才写入偏好；回退得到的结果不保存
  if [ -n "$want_ed" ] && [ "$ed" = "$want_ed" ] && [ "$save_ed" = 1 ]; then
    prefs_set editor "$ed" && ok "已记住编辑器，后续 edit 自动使用（--reset-editor 可清除）"
  fi

  local tmp; tmp=$(mktmp_named "config.json")
  sudo cp "$CFG" "$tmp"; sudo chown "$(id -u):$(id -g)" "$tmp"; chmod 644 "$tmp"
  local before; before=$(shasum "$tmp" | awk '{print $1}')

  # 编辑器运行失败（崩溃、不存在的子命令等）时降级到默认编辑器重试一次
  # ⚠️ 不能写成 `if ! $ed "$tmp"; then local rc=$?`：进了 then 分支正是因为
  # `! $ed` 求值为真，$? 是那次取反的结果，恒为 0，打出来的退出码永远是假的。
  local rc=0
  $ed "$tmp" || rc=$?
  if [ "$rc" != 0 ]; then
    warn "编辑器退出异常（退出码 ${rc}）：$ed"
    if [ "$ed" != "$DEFAULT_EDITOR" ] && editor_usable "$DEFAULT_EDITOR"; then
      if ask "改用 $DEFAULT_EDITOR 重新编辑？" y; then
        prefs_unset editor
        info "已清除该编辑器偏好"
        $DEFAULT_EDITOR "$tmp" || die "默认编辑器也失败了，未做任何修改"
      else
        info "未做任何修改"; return 1
      fi
    else
      die "未做任何修改"
    fi
  fi

  local after; after=$(shasum "$tmp" | awk '{print $1}')
  [ "$before" = "$after" ] && { info "未修改"; return 0; }

  if ! json_valid "$tmp"; then
    bad "JSON 语法错误，未应用"
    python3 -m json.tool "$tmp" 2>&1 | head -5 | sed 's/^/      /' >&2
    local keep; keep=$(keep_path "sb-edit-failed.json") || die "无法创建保留目录"
    cp "$tmp" "$keep" && chmod 600 "$keep" 2>/dev/null
    info "你的修改已保留：$keep"
    dim "该文件含节点凭据，目录权限 700；处理完请自行删除"
    return 1
  fi
  local chk; chk=$(mktmp)
  if ! sudo "$BIN" check -c "$tmp" >"$chk" 2>&1; then
    bad "check 未通过，未应用"
    sed 's/^/      /' "$chk" >&2
    local keep; keep=$(keep_path "sb-edit-failed.json") || die "无法创建保留目录"
    cp "$tmp" "$keep" && chmod 600 "$keep" 2>/dev/null
    info "你的修改已保留：$keep"
    dim "该文件含节点凭据，目录权限 700；处理完请自行删除"
    return 1
  fi
  _cfg_audit_notice "$tmp"
  ok "校验通过"

  if [ "$DRY" = 1 ]; then
    dim "[dry-run] 备份现有配置、清理到最近 10 份、写入 $CFG 并重启服务"
    info "你的修改已通过校验但未应用（-n）。"
    return 0
  fi

  backup_config >/dev/null || die "备份失败，未改动配置"
  prune_backups 10
  sudo cp "$tmp" "$CFG" || die "写入 $CFG 失败，配置未改动（备份仍在）"
  sudo chown root:wheel "$CFG"; sudo chmod 644 "$CFG"
  cmd_restart
}

#=======================================================================
# config audit —— 配置的废弃与合法性审查
#=======================================================================
# 两路合流，互补彼此的盲区。两条都只读、毫秒级、不要 root、不碰网络：
#
#   check 档   `sing-box check` 说的话：废弃但仍接受（WARN，自带官方 migration
#              链接）、已被移除（FATAL，退 1）
#   schema 档  `sing-box schema` 里不存在的键。schema 生成器剔除了全部废弃字段，
#              所以「未知键」≈ 废弃 ∪ 已移除 ∪ 拼错
#
# 为什么非要两路：实测 1.14.0 的 check 对 route.rule_set[].download_detour
# **一个字都不打**（退 0、无输出），而内核每次 run 都往 err 日志里写 deprecated
# 告警。本脚本原先四处 grep 全都只看 check 输出，于是这条告警对脚本完全不可见 ——
# 到 1.16.0 字段真被移除那天，check 会从沉默直接跳到 FATAL，配置一次都起不来。
#
# ⚠️ 找废弃键**不能靠子串计数**。真内核 schema 里 "download_detour" 的子串命中数
# 是 1，那一处是 experimental.clash_api.external_ui_download_detour —— 一个 1.14.0
# 仍然有效的字段。所以 schema 档走结构化键路径比对：按 type 的 const 选定 oneOf
# 分支，再对该分支的 properties 求键差。

# 迁移表覆盖到的内核 minor。内核比它新时 config audit 提示一行「表可能漏项」，退出码不受影响。
# 表（_cfg_pylib 里的 TABLE）加了新 minor 的条目时一并改这里。
CFG_TABLE_COVERS=1.14.0

# _cfg_pylib —— 迁移表 + 路径谓词 + 片段生成，_cfg_audit / _cfg_migrate / _cfg_whitelist_diff /
# _cfg_apply 四处内联 python 共用。<<'PY' 不展开，表是纯 python 字面量，consumer 用
# exec(open(sys.argv[1]).read()) 载入。表的维护方法见 docs/maintaining.md「迁移表怎么维护」。
_cfg_pylib() {
  cat <<'PY'
import json, re, sys

# ---- 迁移表 -------------------------------------------------------------------
# 所有条目钉在 sing-box **v1.14.0** git tag：docs/deprecated.md、docs/migration.md、
# docs/changelog.md、experimental/deprecated/constants.go、option/*.go 的 schema:"omit"。
# 网站是活的（首页已是 1.15.0-alpha），内核是死的——只按 tag 核对，网站只做人工旁证。
# 维护：内核出新 minor 时按 docs/maintaining.md「迁移表怎么维护」更新条目，并改 bash 侧的
# CFG_TABLE_COVERS。链接一律写整段字面量，不拼接——tests 里的锚点核对是 grep 源码做的。

# 每条：id / action（报告「怎么办」那一列的一句话）/ match（key：JSON 路径模式；usage：具名谓词）/ deprecated_in / removed_in /
# tier（deprecated | notice）/ stage（new：内核在 New() 阶段告警，check 能抓；start：只有
# 实跑到 Start() 才告警，只有 run 档能抓；none：内核永远不告警）/ warn（把 check / run 档
# 的 WARN 原文对回本条的正则）/ link（核对过 v1.14.0 docs/ 的链接）/ note / fix（auto：
# --apply 落地；snippet：只出片段；report：只报）/ rewrite（auto 条目的改写规则）。
TABLE = [
    # ---- 1.14.0 ----
    {"id": "download_detour", "action": "改为内联 http_client（--apply 可自动）", "match": {"kind": "key", "paths": ["route.rule_set[type=remote].download_detour"]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "start",
     "warn": r"download_detour", "fix": "auto",
     "rewrite": {"op": "wrap", "new_key": "http_client", "wrap_key": "detour"},
     "link": "https://sing-box.sagernet.org/configuration/rule-set/#http_client",
     "note": "1.14.0 起废弃，应改为内联 http_client: {\"detour\": X}；1.16.0 移除。"
             "v1.14.0 的 migration.md 没有这一条的章节（deprecated 页的 Migration 链接误指 ACME 一节），链接给的是 rule-set 配置页"},
    {"id": "implicit_http_client", "action": "给这条规则集写内联 http_client", "match": {"kind": "usage", "name": "implicit_http_client"},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "start",
     "warn": r"implicit default HTTP client", "fix": "report",
     "link": "https://sing-box.sagernet.org/configuration/rule-set/#http_client",
     "note": "远程规则集既无 http_client 也无 download_detour，顶层 http_clients 与 route.default_http_client 又都空 —— "
             "1.14.0 起用「默认出站」下载规则集是废弃行为（common/httpclient/manager.go:41-44,76-80）。"
             "给这条规则集写内联 http_client: {\"detour\": ...}；不建议引入 default_http_client（全局副作用）"},
    {"id": "inline_acme", "action": "改用 certificate_providers", "match": {"kind": "key", "paths": ["inbounds[].tls.acme"]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "new",
     "warn": r"inline ACME", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-inline-acme-to-certificate-provider",
     "note": "TLS 内联 ACME 选项 1.14.0 废弃，改用 certificate_providers + tls.certificate_provider；1.16.0 移除"},
    {"id": "dns_rule_strategy", "action": "ipv4_only / ipv6_only 按详情里的片段改；prefer_* 直接删", "match": {"kind": "key", "paths": ["dns.rules[**].strategy"]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "start",
     "warn": r"`strategy` DNS rule action", "fix": "snippet",
     "link": "https://sing-box.sagernet.org/configuration/dns/rule_action/#strategy",
     "note": "DNS 规则动作的 strategy 1.14.0 废弃，1.16.0 移除。v1.14.0 的 migration.md 无 migration 章节，"
             "内核 WARN 给的 #migrate-dns-rule-action-strategy-to-rule-items 是死链；链接给的是 rule action 页的 strategy 小节"},
    {"id": "accept_empty", "action": "删掉，改用 evaluate + match_response", "match": {"kind": "key", "paths": ["dns.rules[**].rule_set_ip_cidr_accept_empty"]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "new",
     "warn": r"rule_set_ip_cidr_accept_empty", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching",
     "note": "rule_set_ip_cidr_accept_empty 1.14.0 废弃，随地址过滤一起改为 evaluate + match_response；1.16.0 移除"},
    {"id": "legacy_address_filter", "action": "改为 evaluate + match_response（见详情建议写法）", "match": {"kind": "usage", "name": "legacy_address_filter"},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "start",
     "warn": r"Legacy Address Filter Fields", "fix": "snippet",
     "link": "https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching",
     "note": "DNS 规则带 ip_cidr / ip_is_private / ip_accept_any 却没开 match_response —— 键合法、用法废弃（1.14.0），"
             "1.16.0 起拒绝。改为 evaluate 取响应 + match_response 匹配"},
    {"id": "legacy_address_filter_rs", "action": "规则集是 geoip/IP 类才算；纯域名（geosite-*）可忽略，拿不准用 --deep 定性", "match": {"kind": "usage", "name": "legacy_address_filter_rs"},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "notice", "stage": "start",
     "warn": None, "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching",
     "note": "DNS 规则引用了规则集但没开 match_response：若该规则集含 ip_cidr 条目（如 geoip），这就是废弃的地址过滤用法。"
             "离线看不到规则集内容（dns/router.go:1631-1638 靠规则集元数据判），用 --deep 定性"},
    {"id": "independent_cache", "action": "删掉这个键（--apply 可自动）", "match": {"kind": "key", "paths": ["dns.independent_cache"]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "new",
     "warn": r"independent_cache", "fix": "auto",
     "rewrite": {"op": "delete"},
     "link": "https://sing-box.sagernet.org/migration/#migrate-independent-dns-cache",
     "note": "dns.independent_cache 1.14.0 废弃、1.16.0 移除；migration 原话「Simply remove the field」"},
    {"id": "store_rdrc", "action": "改名为 store_dns: true（--apply 可自动）", "match": {"kind": "key", "paths": ["experimental.cache_file.store_rdrc"]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "new",
     "warn": r"store_rdrc", "fix": "auto",
     "rewrite": {"op": "rename_if_true", "new_key": "store_dns"},
     "link": "https://sing-box.sagernet.org/migration/#migrate-store_rdrc",
     "note": "cache_file.store_rdrc 1.14.0 废弃、1.16.0 移除：值为 true 且没有 store_dns 时改名为 store_dns: true，否则删掉"},
    {"id": "hysteria_v1_tuning", "action": "删掉，改用共享的 quic 参数", "match": {"kind": "key", "paths": [
        "%s[type=hysteria].%s" % (side, f)
        for side in ("outbounds", "inbounds")
        for f in ("recv_window_conn", "recv_window", "recv_window_client", "max_conn_client", "disable_mtu_discovery")]},
     "deprecated_in": "1.14.0", "removed_in": "1.16.0", "tier": "deprecated", "stage": "none",
     "warn": None, "fix": "report",
     "link": "https://sing-box.sagernet.org/changelog/#1140",
     "note": "Hysteria v1 调优字段 1.14.0 废弃、1.16.0 移除，改用共享的 quic 参数（changelog 1.14.0 注 23）。"
             "内核不会告警（option/hysteria.go 标 schema:\"omit\" 但 deprecated/constants.go 无对应 Note），deprecated 页也未列"},
    {"id": "tun_removed_fields", "action": "删掉即可", "match": {"kind": "key", "paths": ["inbounds[type=tun].endpoint_independent_nat", "inbounds[type=tun].gso"]},
     "deprecated_in": "1.11.0", "removed_in": "1.13.0", "tier": "deprecated", "stage": "none",
     "warn": None, "fix": "report",
     "link": "https://sing-box.sagernet.org/configuration/inbound/tun/",
     "note": "源码标 Deprecated: removed，内核静默忽略、不会告警；tun 文档仍把 endpoint_independent_nat 列为有效字段。删掉即可"},
    # 行为变更（notice）
    {"id": "query_type_ip_version_semantics", "action": "确认内部解析也受它影响是想要的", "match": {"kind": "usage", "name": "query_type_or_ip_version"},
     "deprecated_in": "1.14.0", "removed_in": None, "tier": "notice", "stage": "none",
     "warn": None, "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#ip_version-and-query_type-behavior-changes-in-dns-rules",
     "note": "1.14.0 起 query_type / ip_version 也作用于内部解析（resolve 动作、direct 出站的 ICMP、endpoint 自身地址…），"
             "且与遗留地址过滤 / strategy / rule_set_ip_cidr_accept_empty 不能共存于同一份 DNS 配置"},
    # ---- 1.12.0 排期到 1.14.0、内核 1.14.0 仍在 Start() 阶段告警 ----
    {"id": "dns_rule_outbound", "action": "改用出站的 domain_resolver", "match": {"kind": "key", "paths": ["dns.rules[**].outbound"]},
     "deprecated_in": "1.12.0", "removed_in": "1.14.0", "tier": "deprecated", "stage": "start",
     "warn": r"`outbound` DNS rule", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-outbound-dns-rule-items-to-domain-resolver",
     "note": "DNS 规则的 outbound 项 1.12.0 废弃，改用出站的 domain_resolver 拨号字段"},
    {"id": "outbound_domain_strategy", "action": "改为 domain_resolver: {server, strategy}", "match": {"kind": "key", "paths": ["outbounds[].domain_strategy", "endpoints[].domain_strategy"]},
     "deprecated_in": "1.12.0", "removed_in": "1.14.0", "tier": "deprecated", "stage": "start",
     "warn": r"domain[ _]strategy", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-outbound-domain-strategy-option-to-domain-resolver",
     "note": "出站拨号字段 domain_strategy 1.12.0 废弃，改为 domain_resolver: {\"server\": ..., \"strategy\": ...}"},
    {"id": "missing_domain_resolver", "action": "给出站加 domain_resolver，或设 route.default_domain_resolver", "match": {"kind": "usage", "name": "missing_domain_resolver"},
     "deprecated_in": "1.12.0", "removed_in": "1.14.0", "tier": "deprecated", "stage": "start",
     "warn": r"missing domain resolver|domain_resolver", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-outbound-domain-strategy-option-to-domain-resolver",
     "note": "出站 server 是域名却既没有 domain_resolver、route 也没有 default_domain_resolver —— 1.12.0 起靠隐式默认解析是废弃行为"},
    # ---- 1.10–1.13 已被内核拒绝的：进表只为给链接与解释，removed 的定性来自 check 档的 FATAL ----
    {"id": "legacy_dns_servers", "action": "改为 type + server 的新格式", "match": {"kind": "key", "paths": ["dns.servers[].address"]},
     "deprecated_in": "1.12.0", "removed_in": "1.14.0", "tier": "deprecated", "stage": "new",
     "warn": r"legacy DNS server", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-to-new-dns-server-formats",
     "note": "旧式 DNS 服务器（address 字段）1.12.0 废弃、1.14.0 移除，改为 type + server 的新格式"},
    {"id": "legacy_special_outbounds", "action": "改用规则动作 reject / hijack-dns", "match": {"kind": "key", "paths": ["outbounds[type=block]", "outbounds[type=dns]"]},
     "deprecated_in": "1.11.0", "removed_in": "1.13.0", "tier": "deprecated", "stage": "new",
     "warn": r"legacy special outbound", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-legacy-special-outbounds-to-rule-actions",
     "note": "block / dns 特殊出站 1.11.0 废弃，改用规则动作 reject / hijack-dns"},
    {"id": "legacy_inbound_fields", "action": "改用路由规则动作 sniff / resolve", "match": {"kind": "key", "paths": [
        "inbounds[].sniff", "inbounds[].sniff_override_destination", "inbounds[].sniff_timeout", "inbounds[].domain_strategy", "inbounds[].udp_disable_domain_unmapping"]},
     "deprecated_in": "1.11.0", "removed_in": "1.13.0", "tier": "deprecated", "stage": "new",
     "warn": r"legacy inbound fields", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-legacy-inbound-fields-to-rule-actions",
     "note": "入站上的 sniff / domain_strategy 等字段 1.11.0 废弃，改用路由规则动作 sniff / resolve"},
    {"id": "destination_override", "action": "改用 route 动作的 override_address / override_port", "match": {"kind": "key", "paths": ["outbounds[type=direct].override_address", "outbounds[type=direct].override_port"]},
     "deprecated_in": "1.11.0", "removed_in": "1.13.0", "tier": "deprecated", "stage": "new",
     "warn": r"override_address|override_port|destination override", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-destination-override-fields-to-route-options",
     "note": "direct 出站的 override_address / override_port 1.11.0 废弃，改用 route 动作的同名选项"},
    {"id": "wireguard_outbound", "action": "改为 endpoints[] 的 wireguard 端点", "match": {"kind": "key", "paths": ["outbounds[type=wireguard]"]},
     "deprecated_in": "1.11.0", "removed_in": "1.13.0", "tier": "deprecated", "stage": "new",
     "warn": r"WireGuard outbound", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#migrate-wireguard-outbound-to-endpoint",
     "note": "WireGuard 出站 1.11.0 废弃，改为 endpoints[] 里的 wireguard 端点"},
    {"id": "tun_address_fields", "action": "改为 address / route_address / route_exclude_address", "match": {"kind": "key", "paths": [
        "inbounds[type=tun].%s" % f for f in ("inet4_address", "inet6_address", "inet4_route_address", "inet6_route_address",
                                              "inet4_route_exclude_address", "inet6_route_exclude_address")]},
     "deprecated_in": "1.10.0", "removed_in": "1.12.0", "tier": "deprecated", "stage": "new",
     "warn": r"legacy tun address fields", "fix": "report",
     "link": "https://sing-box.sagernet.org/migration/#tun-address-fields-are-merged",
     "note": "tun 的 inet4_*/inet6_* 地址字段 1.10.0 合并为 address / route_address / route_exclude_address，1.12.0 移除"},
    {"id": "ipcidr_match_source", "action": "改名为 rule_set_ip_cidr_match_source", "match": {"kind": "key", "paths": ["dns.rules[**].rule_set_ipcidr_match_source", "route.rules[**].rule_set_ipcidr_match_source"]},
     "deprecated_in": "1.10.0", "removed_in": "1.11.0", "tier": "deprecated", "stage": "new",
     "warn": r"rule_set_ipcidr_match_source", "fix": "report",
     "link": "https://sing-box.sagernet.org/deprecated/#match-source-rule-items-are-renamed",
     "note": "rule_set_ipcidr_match_source 1.10.0 改名为 rule_set_ip_cidr_match_source，1.11.0 移除"},
]
BY_ID = dict((e["id"], e) for e in TABLE)


# ---- 路径模式 ------------------------------------------------------------------
# 语法：段用 . 连接；段可带 [] 任意下标、[k=v] 按子键筛、[**] 任意下标并递归进 logical
# 子规则的 rules。以筛选段结尾的模式命中的是元素本身（outbounds[type=block]）。
_SEG = re.compile(r"^([A-Za-z0-9_$]+)(?:\[(.*)\])?$")

def _elems(lst, p, filt):
    for idx, el in enumerate(lst):
        elp = "%s[%d]" % (p, idx)
        if filt == "**":
            yield (elp, lst, idx, el)
            if isinstance(el, dict) and isinstance(el.get("rules"), list):
                for h in _elems(el["rules"], elp + ".rules", "**"):
                    yield h
        elif filt == "":
            yield (elp, lst, idx, el)
        else:
            k, _, v = filt.partition("=")
            if isinstance(el, dict) and str(el.get(k, "")) == v:
                yield (elp, lst, idx, el)

def find_paths(cfg, pattern):
    """返回 [(path, container, key, value)]：container[key] 就是命中的值。"""
    segs = pattern.split(".")
    out = []
    def rec(node, i, path):
        m = _SEG.match(segs[i])
        name, filt = m.group(1), m.group(2)
        if not isinstance(node, dict) or name not in node:
            return
        val = node[name]
        p = (path + "." + name) if path else name
        last = i == len(segs) - 1
        if filt is None:
            if last:
                out.append((p, node, name, val))
            else:
                rec(val, i + 1, p)
        elif isinstance(val, list):
            for (ep, c, k, el) in _elems(val, p, filt):
                if last:
                    out.append((ep, c, k, el))
                else:
                    rec(el, i + 1, ep)
    rec(cfg, 0, "")
    return out


# ---- 具名谓词（用法条件：A / B 表达不了的那几条）-----------------------------
ADDR_FIELDS = ("ip_cidr", "ip_is_private", "ip_accept_any")

def _dns_rules(cfg):
    rules = (cfg.get("dns") or {}).get("rules")
    if not isinstance(rules, list):
        return []
    return [h for h in _elems(rules, "dns.rules", "**") if isinstance(h[3], dict)]

def _is_ip(s):
    try:
        import ipaddress
        ipaddress.ip_address(s)
        return True
    except Exception:
        return False

def u_implicit_http_client(cfg):
    route = cfg.get("route") or {}
    if cfg.get("http_clients") or route.get("default_http_client"):
        return []
    return [h for h in _elems(route.get("rule_set") or [], "route.rule_set", "type=remote")
            if isinstance(h[3], dict) and "http_client" not in h[3] and "download_detour" not in h[3]]

def u_legacy_address_filter(cfg):
    return [h for h in _dns_rules(cfg)
            if any(f in h[3] for f in ADDR_FIELDS) and not h[3].get("match_response")]

def u_legacy_address_filter_rs(cfg):
    return [h for h in _dns_rules(cfg)
            if h[3].get("rule_set") and not h[3].get("match_response") and not any(f in h[3] for f in ADDR_FIELDS)]

def u_query_type_or_ip_version(cfg):
    return [h for h in _dns_rules(cfg) if "query_type" in h[3] or "ip_version" in h[3]]

def u_missing_domain_resolver(cfg):
    if (cfg.get("route") or {}).get("default_domain_resolver"):
        return []
    out = []
    for h in _elems(cfg.get("outbounds") or [], "outbounds", ""):
        el = h[3]
        if isinstance(el, dict) and isinstance(el.get("server"), str) and el["server"] \
                and not _is_ip(el["server"]) and "domain_resolver" not in el:
            out.append(h)
    return out

USAGE = {
    "implicit_http_client": u_implicit_http_client,
    "legacy_address_filter": u_legacy_address_filter,
    "legacy_address_filter_rs": u_legacy_address_filter_rs,
    "query_type_or_ip_version": u_query_type_or_ip_version,
    "missing_domain_resolver": u_missing_domain_resolver,
}

def table_hits(cfg, entry):
    m = entry["match"]
    if m["kind"] == "key":
        out = []
        for pat in m["paths"]:
            out.extend(find_paths(cfg, pat))
        return out
    return USAGE[m["name"]](cfg)


# ---- 片段（snippet 型条目）-------------------------------------------------------
# 按 v1.14.0 源码语义推导，未经行为验证。不落地，报告里注明需人工核对。
_RULE_ACTION_KEYS = ("action", "server", "strategy", "rewrite_ttl", "disable_cache", "client_subnet",
                     "match_response", "rule_set_ip_cidr_accept_empty", "outbound")
_CARRY = ("rewrite_ttl", "disable_cache", "client_subnet")
QT = ["A", "AAAA", "HTTPS"]

def snippet_address_filter(rule, path):
    # dns/router.go:294-298：遗留规则对非地址查询整条跳过；地址查询用本条 server 查，
    # 响应不匹配则继续下一条。等价新形式是两条，且两条都限定 query_type；
    # evaluate 用**原规则的 server**（官方示例换成 remote evaluate 再 route 到 local，那换了决定服务器，不是等价改写）。
    idx = re.findall(r"\[(\d+)\]", path)
    tag = "mig-af-%s" % (idx[-1] if idx else "0")
    cond = dict((k, v) for k, v in rule.items() if k not in ADDR_FIELDS and k not in _RULE_ACTION_KEYS)
    ev = dict(cond)
    ev["query_type"] = QT
    ev["action"] = "evaluate"
    if "server" in rule:
        ev["server"] = rule["server"]
    for k in _CARRY:
        if k in rule:
            ev[k] = rule[k]
    ev["tag"] = tag
    rs = dict(cond)
    rs["query_type"] = QT
    rs["match_response"] = tag
    for k in ADDR_FIELDS:
        if k in rule:
            rs[k] = rule[k]
    rs["action"] = "respond"
    return "\n".join(json.dumps(x, ensure_ascii=False) for x in (ev, rs))

def snippet_strategy(rule, path, value):
    # dns/client.go:261-266,616-630：ipv4_only = AAAA 查询直接回空 NOERROR、HTTPS 应答剥掉 ipv6hint；
    # ipv6_only 对称；prefer_* 只影响内部 Lookup 排序，对客户端查询无效果。
    if value not in ("ipv4_only", "ipv6_only"):
        return None
    cond = dict((k, v) for k, v in rule.items() if k not in _RULE_ACTION_KEYS)
    pre = dict(cond)
    pre["query_type"] = ["AAAA" if value == "ipv4_only" else "A"]
    pre["action"] = "predefined"
    pre["rcode"] = "NOERROR"
    return json.dumps(pre, ensure_ascii=False)

def snippet_for(entry, hit):
    """返回 (片段, 附加说明)。片段为 None 表示不给片段。"""
    path, container, key, value = hit
    if entry["id"] == "legacy_address_filter":
        return ("在原规则位置替换为下面两条：\n" + snippet_address_filter(value, path), None)
    if entry["id"] == "dns_rule_strategy":
        rule = container if isinstance(container, dict) else {}
        s = snippet_strategy(rule, path, value)
        if s is None:
            return (None, "prefer_* 只影响内部 Lookup 的排序，对客户端查询无效果：删掉即可")
        return ("在原规则之前插入下面这条（HTTPS 应答的 ipv6hint/ipv4hint 剥离无等价写法，注明）：\n" + s
                + "\n然后删掉原规则的 strategy", None)
    return (None, None)


# ---- 版本 ---------------------------------------------------------------------
def ver_tuple(v):
    out = []
    for x in re.split(r"[.\-]", str(v or "")):
        if x.isdigit():
            out.append(int(x))
        else:
            break
    return tuple(out + [0] * (3 - len(out)))[:3]
PY
}

# 每条发现一行，TAB 分隔，供调用方自行渲染：
#   <tier>\t<source>\t<json 路径>\t<说明>\t<官方迁移链接或空>
# tier ∈ removed（对应退 1）/ deprecated（对应退 2）；source ∈ check / schema
#
# $1 配置路径。
#
# ⚠️ **不用 sudo。** 需求写明发现层「只读、毫秒级、不要 root、不碰网络」，而
# `sing-box check -c` 本来就只读配置，不需要提权（$CFG 是 644）。更要紧的是
# cmd_verify 原先通篇没有一次 sudo —— 一个只读诊断命令不该因为多了一步配置审查
# 就开始要密码，在无 TTY 的环境（cron、ssh host singbox verify）里那等于必然失败。
#
# 返回值：0 = 审完了（发现写在 stdout），1 = **审不了**（读不到配置、内核起不来）。
# 这两件事必须分开：把「审不了」报成发现，就是把「配置已经坏了」这个结论强加给
# 一次根本没做成的检查。
# $1 配置  $2 沙箱日志路径（可空）  $3 =1 表示沙箱建链成功、日志完整（Start() 走完了）
_cfg_audit() {
  local cfg="$1" runlog="${2:-}" complete="${3:-0}"
  local chk rc

  # 前置闸门：内核得先能应答。$BIN 损坏、权限不对、根本没装的时候 check 同样
  # 退非 0，而那种失败长得跟「内核拒绝配置」一模一样 —— 不先分开，一个装坏了的
  # 内核会被报成「配置里有已移除字段」，结论完全是误导的。
  local kver
  kver=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
  # 返回 1（审不了）而不是 0（审完了，没发现）—— 内核问不出版本号的时候打一句
  # 「配置里没有废弃字段」，跟把 sudo 的报错当成发现是同一类误导，只是方向相反。
  [ -n "$kver" ] || return 1

  #--- check 档 ---------------------------------------------------------
  [ -r "$cfg" ] || return 1
  chk=$("$BIN" check -c "$cfg" 2>&1); rc=$?

  # A / B 两路的原始行先收进 $raw，最后由合并那段 python 按路径去重、合并来源，
  # 再写 stdout。内核 < 1.14.0 时只有 A 路，原样吐出。
  local raw; raw=$(mktmp)
  {
  if [ "$rc" != 0 ]; then
    # 退非 0 有两种完全不同的含义，必须先分开：
    #   内核拒绝了配置        → 这是发现（tier=removed）
    #   审查本身没做成        → 这不是发现，是「审不了」
    # 判据是输出像不像内核自己的诊断。不分开的话，任何让 check 跑不成的原因
    # （文件读不到、内核损坏、sudo 要密码）都会被报成「配置里有已移除字段」，
    # 而那个结论会一路传到 verify 的退出码上去。
    local names
    names=$(printf '%s\n' "$chk" | sed -n 's/.*unknown field \([A-Za-z0-9_]*\).*/\1/p' | sort -u)
    if [ -n "$names" ]; then
      printf '%s\n' "$names" | while IFS= read -r n; do
        [ -n "$n" ] || continue
        printf 'removed\tcheck\t%s\t内核拒绝该字段（已从本版本移除）\t%s\n' \
               "$n" "https://sing-box.sagernet.org/deprecated/"
      done
    elif printf '%s\n' "$chk" | grep -q 'FATAL'; then
      # 是内核在说话，只是不是 unknown field 那个形状。整行原文奉上 ——
      # 宁可信息糙，也不编一个键路径出来。
      printf '%s\n' "$chk" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'removed\tcheck\t-\t%s\t%s\n' "$line" "https://sing-box.sagernet.org/deprecated/"
      done
    else
      return 1        # 不是内核在说话 —— 审不了，不是配置坏了
    fi
  else
    # 退 0 但有话说 = 废弃仍接受。官方 WARN 自带 migration 锚点，原样带出去。
    printf '%s\n' "$chk" | grep -i deprecated 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] || continue
      local url
      url=$(printf '%s\n' "$line" | sed -n 's|.*\(https://sing-box\.sagernet\.org/migration/[^ ]*\).*|\1|p')
      printf 'deprecated\tcheck\t-\t%s\t%s\n' "$line" "$url"
    done
  fi
  } >"$raw"

  #--- schema 档 --------------------------------------------------------
  # 内核 < 1.14.0 的 schema 是否同样剔除废弃字段，手上没有老内核可实测。闸门保守：
  # 低于 1.14.0 就只信 check 档，不拿一个没验过的前提去报废弃。迁移表同理：
  # 表里的谓词全是按 1.14.0 源码写的，不往老内核上套。
  if ver_gt 1.14.0 "$kver"; then
    cat "$raw"
    return 0
  fi

  local sch; sch=$(mktmp)
  # schema 拿不到就只跳过 B 路，C 路照跑：表是离线的，不依赖内核吐 schema。
  "$BIN" schema >"$sch" 2>/dev/null || : >"$sch"

  [ -s "$sch" ] && python3 - "$cfg" "$sch" <<'PY' >>"$raw"
import json, sys

cfg_path, schema_path = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(cfg_path))
    sch = json.load(open(schema_path))
except Exception:
    sys.exit(0)          # 配置本身不是合法 JSON —— 那是 check 档的活，这里不抢

defs = sch.get("$defs", sch.get("definitions", {}))

DEPRECATED_URL = "https://sing-box.sagernet.org/deprecated/"
# B 路只说「schema 不认识」，不猜它该改成什么 —— 迁移说明与链接统一由迁移表给，
# 合并那一步会用表的 note / link 覆盖同路径的这一行。表外的未知键就只有这句。

def deref(node, depth=0):
    while isinstance(node, dict) and "$ref" in node and depth < 64:
        ref = node["$ref"]
        if not ref.startswith("#/$defs/") and not ref.startswith("#/definitions/"):
            return {}
        node = defs.get(ref.rsplit("/", 1)[-1], {})
        depth += 1
    return node if isinstance(node, dict) else {}

def json_type(v):
    if isinstance(v, bool):  return "boolean"      # bool 是 int 的子类，必须先判
    if isinstance(v, dict):  return "object"
    if isinstance(v, list):  return "array"
    if isinstance(v, str):   return "string"
    if isinstance(v, (int, float)): return "number"
    return "null"

def pick_by_const(branches, value):
    """按 discriminator 选分支。RuleSet 的三分支（inline/local/remote）走这条。

    ⚠️ 判别键冲突必须能**否决**整个分支，不能「命中任意一个就算数」：
    RuleSet 的 local 与 remote 分支都有 format:enum["source","binary"]，
    一条 {"type":"remote", "format":"binary", ...} 若只看「有没有键命中」，
    会先撞上 local 分支——于是 url / update_interval / http_client 三个
    remote 独有的合法键全被报成「schema 不认识」。

    另注意 inline 分支的 type 是 enum ["inline", ""]，而 inline 条目通常压根
    不写 type —— 所以「配置里没这个键」在 allowed 含 "" 时要算隐式命中。

    规则的动作分支（DNSRule / Rule 的 allOf 第二段）判别键是 action:const，
    而默认动作 route 的分支**不**把 action 列进 required：配置里没写 action 时，
    没有任何分支能靠 const 命中，就取唯一一个「缺的判别键不在 required 里」的分支。"""
    if not isinstance(value, dict):
        return None
    explicit, implicit, fallback = [], [], []
    for b in branches:
        bd = flatten(b, value)
        if bd is None:
            continue
        props = bd.get("properties", {})
        required = bd.get("required", [])
        vetoed = False
        hits = 0
        soft = 0
        for k, spec in props.items():
            spec = deref(spec)
            if "const" in spec:
                allowed = [spec["const"]]
            elif "enum" in spec:
                allowed = spec["enum"]
            else:
                continue
            if k in value:
                if value[k] in allowed:
                    hits += 1
                else:
                    vetoed = True
                    break
            elif "" in allowed:
                soft += 1
            elif k in required:
                # 判别键是必填的却没写：这个分支不可能是它。reject 动作分支的 method
                # 枚举含 ""，不这样否决的话，一条没写 action 的普通规则会被「隐式命中」
                # 到 reject 上去，outbound 随即被报成 schema 不认识。
                vetoed = True
                break
        if vetoed:
            continue
        if hits:
            explicit.append(bd)
        elif soft:
            implicit.append(bd)
        else:
            fallback.append(bd)
    if explicit:
        return explicit[0]
    if implicit:
        return implicit[0]
    if len(fallback) == 1:
        return fallback[0]
    return None

def flatten(schema, value):
    """deref 之后把 allOf 摊平成一个 dict：properties 取并集，
    additionalProperties / unevaluatedProperties 取第一个见到的；part 里的 oneOf/anyOf
    先按 value 选分支。任一 part 归不到分支就返回 None —— 调用方收手，宁可漏报。
    真 schema 的 DNSRule / Rule 就是 oneOf[ {unevaluatedProperties:false,
    allOf:[{匹配字段}, {oneOf: 动作分支}]} ] 这个形状，上一轮的 walker 在这里一律收手，
    于是 dns.rules[].strategy 这种 schema:"omit" 的键在真内核上根本抓不到。"""
    schema = deref(schema)
    if not isinstance(schema, dict):
        return None
    if "allOf" not in schema:
        return schema
    merged = dict((k, v) for k, v in schema.items() if k != "allOf")
    props = dict(merged.get("properties", {}))
    for part in schema["allOf"]:
        part = deref(part)
        picked = None
        for comb in ("oneOf", "anyOf"):
            if comb in part:
                picked = pick_by_const(part[comb], value) or pick_by_type(part[comb], value)
                if picked is None:
                    return None
                part = picked
                break
        part = flatten(part, value)
        if part is None:
            return None
        props.update(part.get("properties", {}))
        for k in ("additionalProperties", "unevaluatedProperties"):
            if k in part:
                merged.setdefault(k, part[k])
    merged["properties"] = props
    return merged

def pick_by_type(branches, value):
    want = json_type(value)
    for b in branches:
        bd = deref(b)
        t = bd.get("type")
        if t == want or (isinstance(t, list) and want in t):
            return bd
    return None

found = []

def walk(value, schema, path):
    schema = flatten(schema, value)
    if not isinstance(schema, dict) or not schema:
        return
    for comb in ("oneOf", "anyOf"):
        if comb in schema:
            br = pick_by_const(schema[comb], value) or pick_by_type(schema[comb], value)
            if br is None:
                return       # 归不到分支就收手：宁可漏报，也不报一个编出来的键路径
            merged = dict(br)
            for k, v in schema.items():
                if k not in ("oneOf", "anyOf"):
                    merged.setdefault(k, v)
            walk(value, merged, path)
            return
    if isinstance(value, dict):
        props = schema.get("properties", {})
        extra_ok = schema.get("additionalProperties", schema.get("unevaluatedProperties", True))
        for k in value:
            sub = path + "." + k if path else k
            if k in props:
                walk(value[k], props[k], sub)
            elif extra_ok is False:
                found.append(sub)
    elif isinstance(value, list):
        items = schema.get("items")
        if items is not None:
            for i, v in enumerate(value):
                walk(v, items, "%s[%d]" % (path, i))

walk(cfg, sch, "")

for pth in found:
    sys.stdout.write("\t".join(("deprecated", "schema", pth,
                                "schema 里没有这个键（已废弃、已移除，或拼错）", DEPRECATED_URL)) + "\n")
PY

  #--- 迁移表档 + 沙箱日志档 + 合并 -------------------------------------------
  # C 路：表里的谓词逐条对配置求值，能表达 A / B 都表达不了的「键合法但用法废弃」。
  # D 路：$runlog 给了就 grep 内核 Start() 阶段的 WARN（版本无关，表外的新条目也抓得到）。
  # 合并：按 JSON 路径去重，来源按 check+schema+table+run 合并，tier 取最高；说明与链接
  # 以表为准覆盖（A / D 从 WARN 抠出的链接可能是死链，B 只会说「schema 不认识」）。
  # A / D 的 WARN 行本身没有路径：先用表条目的 warn 正则认出是哪条，再贴到 C 路命中的
  # 路径上；C 路没命中就以条目 id 当路径单独成行。「removed」只可能来自 A（内核拒绝）。
  local lib; lib=$(mktmp); _cfg_pylib >"$lib"
  python3 - "$lib" "$cfg" "$raw" "$runlog" "$kver" "$complete" <<'PY'
import json, re, sys
exec(open(sys.argv[1]).read())
cfg_path, raw_path, runlog, kver, complete = sys.argv[2:7]
try:
    cfg = json.load(open(cfg_path))
except Exception:
    cfg = None
rows = []            # {path, tier, src:set, desc, url, snippet, eid, action}
RANK = {"removed": 3, "deprecated": 2, "notice": 1}
SRC_ORDER = ("check", "schema", "table", "run")

def add(path, tier, src, desc, url, snippet=None, eid=None, action=None):
    # 去重键是路径；没有路径的行（表外的 WARN / FATAL 原文，path 为 "-"）以原文为键，
    # 否则两条不同的表外 WARN 会被判成同一条，第二条起静默丢失。
    for r in rows:
        if r["path"] == path and (path != "-" or r["desc"] == desc):
            r["src"].add(src)
            if RANK[tier] > RANK[r["tier"]]:
                r["tier"] = tier
            if src == "table":          # 表的说明与链接覆盖 A / B 的
                r["desc"], r["url"], r["snippet"], r["eid"], r["action"] = desc, url, snippet, eid, action
            return r
    r = {"path": path, "tier": tier, "src": set([src]), "desc": desc, "url": url, "snippet": snippet, "eid": eid,
         "action": action}
    rows.append(r)
    return r

# C 路
if isinstance(cfg, dict):
    for e in TABLE:
        for hit in table_hits(cfg, e):
            note = e["note"]
            if e["tier"] == "deprecated" and e["removed_in"] and ver_tuple(e["removed_in"]) <= ver_tuple(kver):
                note += "（文档称已在 %s 移除，本内核仍接受）" % e["removed_in"]
            snippet, extra = snippet_for(e, hit)
            if extra:
                note += "。" + extra
            add(hit[0], e["tier"], "table", note, e["link"], snippet, e["id"], e["action"])

def entry_for(text):
    for e in TABLE:
        if e["warn"] and re.search(e["warn"], text):
            return e
    return None

def attach_warn(text, src, tier, url):
    """把一行内核 WARN / FATAL 贴到表条目命中的路径上。"""
    e = entry_for(text)
    if e is None:
        add("-", tier, src, text, url, None, None,
            "内核拒绝，看原文" if tier == "removed" else "内核告警但迁移表未收录，按链接迁移（表该补条目了）")
        return
    mine = [r for r in rows if r["eid"] == e["id"]]
    if not mine and e["id"] == "legacy_address_filter":
        # 离线只能给 notice 的规则集地址过滤：内核既然告警了，就升为 deprecated
        mine = [r for r in rows if r["eid"] == "legacy_address_filter_rs"]
        for r in mine:
            r["desc"] = BY_ID["legacy_address_filter"]["note"] + "（内核已告警：引用规则集的规则里至少一条是遗留地址过滤用法，WARN 全局只打一次，分不出是哪条，全部列出）"
    if mine:
        for r in mine:
            add(r["path"], tier, src, r["desc"], r["url"])
    else:
        add(e["id"], tier, src, e["note"], e["link"], None, e["id"], e["action"])

# A / B 路的原始行。B（schema）先于 A（check）处理：A 的「unknown field X」要贴到
# 带完整路径的那一行上，而那一行可能只有 B 给得出（表外的键 C 路没有）。
raw_rows = []
for line in open(raw_path):
    line = line.rstrip("\n")
    if not line:
        continue
    f = line.split("\t")
    while len(f) < 5:
        f.append("")
    raw_rows.append(f[:5])
raw_rows.sort(key=lambda f: 0 if f[1] == "schema" else 1)
for tier, src, path, desc, url in raw_rows:
    if src == "schema":
        add(path, "deprecated", "schema", desc, url, None, None, "核对拼写；schema 不认识的键多半已废弃或移除，查 deprecated 页")
    elif tier == "removed" and path not in ("-", ""):
        # unknown field X：贴到叶子名等于 X 的路径上；没有就单独成行
        mine = [r for r in rows if r["path"].rsplit(".", 1)[-1].split("[", 1)[0] == path]
        if mine:
            for r in mine:
                add(r["path"], "removed", "check", r["desc"], r["url"])
                if r["eid"] is None:
                    r["action"] = "内核已不认识这个字段，删掉或按 deprecated 页迁移"
        else:
            add(path, "removed", "check", desc, url, None, None, "内核已不认识这个字段，删掉或按 deprecated 页迁移")
    elif tier == "removed":
        attach_warn(desc, "check", "removed", url)
    else:
        attach_warn(desc, "check", "deprecated", url)

# D 路
if runlog:
    try:
        for line in open(runlog, errors="replace"):
            if "deprecated in sing-box" not in line:
                continue
            text = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
            text = re.sub(r"^.*?WARN\[\d+\]\s*", "", text)
            m = re.search(r"(https://sing-box\.sagernet\.org/\S+)", text)
            attach_warn(text, "run", "deprecated", m.group(1) if m else "")
    except Exception:
        pass

# 反向定性：沙箱建链成功（Start() 走完、规则集都加载了）而内核没打地址过滤的 WARN，
# 说明那些规则集不含 ip_cidr 条目——离线只能存疑的 notice 到这里有了答案，撤掉。
# 日志不完整（没建链）时不撤：规则集下不到，DNS 那几条 WARN 根本走不到。
# 配置里另有直接的地址过滤规则时也不撤：那条 WARN 全局只打一次（v1.14.0 dns/router.go:156
# 是 common.Any(newRules, WithAddressLimit)），有它说明不了 rule_set 那几条是不是遗留用法。
dropped = []
if runlog and complete == "1" and not any(r["eid"] == "legacy_address_filter" for r in rows):
    dropped = [r for r in rows if r["eid"] == "legacy_address_filter_rs" and "run" not in r["src"]]
    rows = [r for r in rows if r not in dropped]

def enc(sn):
    return "" if not sn else sn.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

def natkey(p):
    # rule_set[10] 要排在 rule_set[2] 之后：把路径里的数字段按整数比
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", p)]
rows.sort(key=lambda r: (-RANK[r["tier"]], r["path"] in ("-", ""), natkey(r["path"])))
def doc_id(r):
    # 第 8 列：有解读文档的条目 id（fix != auto 才有一节；A / B 路的表外发现没有 id）
    e = BY_ID.get(r["eid"]) if r["eid"] else None
    return r["eid"] if e is not None and e.get("fix") != "auto" else ""
for r in rows:
    src = "+".join(x for x in SRC_ORDER if x in r["src"])
    out = [r["tier"], src, r["path"], r["desc"], r["url"], enc(r["snippet"]), r["action"] or "", doc_id(r)]
    sys.stdout.write("\t".join(out) + "\n")
# 撤掉的不能无声：报告端拿这一行在表格后面说明「--deep 排除了什么、为什么」。
# tier=dropped 不进表格也不进退出码；挂载点（_cfg_audit_notice）跳过它。
if dropped:
    paths = " ".join(sorted(set(r["path"] for r in dropped), key=natkey))
    out = ["dropped", "run", paths, "引用的规则集经沙箱确认不含 IP 条目，不是废弃的地址过滤用法", "", "", "",
           "legacy_address_filter_rs"]
    sys.stdout.write("\t".join(out) + "\n")
PY
}

# 挂载点专用：只报，不参与调用方的退出码判定，返回值恒为 0。
# install / update / doctor 各有各的成败判据，配置现代性不该把它们打死 —— 这也是
# 原先那四处 grep 里唯一正确的部分，收敛时原样保留。
# $1 配置路径  $2 沙箱日志路径（可空：cmd_update 阶段 1 的沙箱顺手收割，喂给 D 路。
#    那个沙箱建链失败会直接 die，所以走到这里的日志一定是完整的）
_cfg_audit_notice() {
  local cfg="$1" runlog="${2:-}"
  [ -f "$cfg" ] || return 0
  local rows; rows=$(mktmp)
  # 审不了就闭嘴退场：这几个挂载点是搭车的，没做成的检查不该在 install / update
  # 的输出里制造噪声，更不该把它们的成败带偏。
  _cfg_audit "$cfg" "$runlog" "$([ -n "$runlog" ] && echo 1 || echo 0)" >"$rows" 2>/dev/null || return 0
  # ⚠️ 不写 $(grep -c ... || echo 0)：无命中时 grep 退 1，那个兜底会把计数变成
  # "0\n0"。自检点名过这个形状。
  # notice 档是行为变更提示，不算废弃；挂载点只报 removed / deprecated
  local n; n=$(awk -F'\t' '$1=="removed"||$1=="deprecated"{n++} END{print n+0}' "$rows")
  [ "${n:-0}" != 0 ] || return 0
  warn "配置里有 ${n} 处废弃/未知字段（详情跑：$(basename "$0") config audit）："
  local tier source path desc url snippet
  while IFS="$(printf '\t')" read -r tier source path desc url snippet; do
    [ -n "$tier" ] || continue
    case "$tier" in notice|dropped) continue ;; esac
    printf '        [%s/%s] %s —— %s\n' "$tier" "$source" "$path" "$desc" >&2
  done <"$rows"
  return 0
}

# 改写层。规则来自迁移表里 fix=auto 的条目（_cfg_pylib 的 TABLE），目前 3 条，全是
# 纯键名改写、官方 migration.md 有完整前后 JSON 对照且语义无分支：
#   route.rule_set[type=remote].download_detour: "X"  →  http_client: {"detour": "X"}   （wrap）
#   dns.independent_cache                              →  删键                            （delete）
#   experimental.cache_file.store_rdrc: true           →  store_dns: true；否则删键        （rename_if_true）
# _cfg_migrate 与 _cfg_whitelist_diff **共用这张表**：改写按它做，白名单按它算「该有哪些 diff」。
#
# download_detour 用内联 http_client 对象，不引顶层 http_clients[] 数组、不设
# route.default_http_client。理由是实测出来的：check 放过 tag 引用错误（http_client:"rs_dl"
# 而顶层 tag 是 "rs-dl"，check 退 0），只有真跑起来才 FATAL。内联写法没有 tag 引用，从源头
# 免疫这一类错误；而 default_http_client 会改变所有隐式下载通道（external_ui_download、
# 证书提供者…），影响面远超规则集，四道验收一道都挡不住。
_cfg_migrate() {
  local src="$1" dst="$2"
  # 测试后门：直接拿一份现成的「改写结果」顶上，好让白名单 diff 能收到**坏的**
  # 输入。不给这个注入点，第 1 道验收就只能被自己产出的正确结果喂——它永远绿，
  # 也就永远测不出它到底拦不拦得住。
  if [ -n "${SB_FAKE_MIGRATED:-}" ] && [ -f "$SB_FAKE_MIGRATED" ]; then
    cp "$SB_FAKE_MIGRATED" "$dst"
    return $?
  fi
  local lib; lib=$(mktmp); _cfg_pylib >"$lib"
  python3 - "$lib" "$src" "$dst" <<'PY'
import json, sys
exec(open(sys.argv[1]).read())
src, dst = sys.argv[2], sys.argv[3]
d = json.load(open(src))
for e in TABLE:
    if e["fix"] != "auto":
        continue
    op = e["rewrite"]["op"]
    for path, container, key, value in table_hits(d, e):
        # 逐字搬移：不解析、不规范化、不补默认值。值搬错是四道验收全挡不住的那一型
        # （② 型），唯一的防线就是这几行本身精确到值。
        if op == "wrap":
            container[e["rewrite"]["new_key"]] = {e["rewrite"]["wrap_key"]: container.pop(key)}
        elif op == "delete":
            container.pop(key)
        elif op == "rename_if_true":
            v = container.pop(key)
            if v is True and e["rewrite"]["new_key"] not in container:
                container[e["rewrite"]["new_key"]] = True
json.dump(d, open(dst, "w"), ensure_ascii=False, indent=2)
open(dst, "a").write("\n")
PY
}

# _cfg_auto_hits <cfg>：每条 auto 规则在配置里的命中数，一行一条：id<TAB>n<TAB>模式
# --apply 的确认提示、「无需改写」早退与第 4 道归零都用它。
_cfg_auto_hits() {
  local lib; lib=$(mktmp); _cfg_pylib >"$lib"
  python3 - "$lib" "$1" <<'PY'
import json, sys
exec(open(sys.argv[1]).read())
try:
    d = json.load(open(sys.argv[2]))
except Exception:
    d = {}
for e in TABLE:
    if e["fix"] == "auto":
        print("%s\t%d\t%s" % (e["id"], len(table_hits(d, e)), " / ".join(e["match"]["paths"])))
PY
}

# 第 1 道验收：离线白名单结构 diff。
# 结构 diff 而非文本 diff —— 改写会把 http_client 放到键序末尾，文本 diff 会把这个
# 无语义的位移报成改动。
# 「该有哪些 diff」从**原配置** + 规则表独立推出来（不看改写结果）：每处命中允许一个删除，
# wrap / rename 型再允许一个配对的新增，且新增的值必须等于映射后的旧值（store_rdrc → store_dns
# 的映射是恒等）。此外的任何差异都是越界。
_cfg_whitelist_diff() {
  local lib; lib=$(mktmp); _cfg_pylib >"$lib"
  python3 - "$lib" "$1" "$2" <<'PY'
import json, sys
exec(open(sys.argv[1]).read())

def flat(o, p="", out=None):
    if out is None:
        out = {}
    if isinstance(o, dict):
        for k, v in o.items():
            flat(v, (p + "." + k) if p else k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            flat(v, "%s[%d]" % (p, i), out)
    else:
        out[p] = o
    return out

try:
    orig = json.load(open(sys.argv[2]))
    a = flat(orig)
    b = flat(json.load(open(sys.argv[3])))
except Exception as e:
    sys.stderr.write("      读不出配置：%s\n" % e)
    sys.exit(1)

MISS = object()
# expected: path -> 期望在改写结果里的值（MISS = 期望被删）；pairs: 删除路径 -> (新增路径, 期望值)
expected, pairs = {}, {}
for e in TABLE:
    if e["fix"] != "auto":
        continue
    rw = e["rewrite"]
    for path, container, key, value in table_hits(orig, e):
        expected[path] = MISS
        parent = path.rsplit(".", 1)[0]
        if rw["op"] == "wrap":
            newp = "%s.%s.%s" % (parent, rw["new_key"], rw["wrap_key"])
            expected[newp] = value
            pairs[path] = (newp, value)
        elif rw["op"] == "rename_if_true" and value is True and rw["new_key"] not in container:
            newp = "%s.%s" % (parent, rw["new_key"])
            expected[newp] = True
            pairs[path] = (newp, True)

problems = []
for k in sorted(set(a) | set(b)):
    av, bv = a.get(k, MISS), b.get(k, MISS)
    if av is bv or av == bv:
        continue
    if k in expected:
        want = expected[k]
        if want is MISS and bv is MISS:
            newp = pairs.get(k)
            if newp is not None:
                got = b.get(newp[0], MISS)
                if got is MISS:
                    problems.append("%s 被删掉了，但 %s 没有出现 —— %s 丢了" % (k, newp[0], newp[0].rsplit(".", 1)[-1]))
                elif got != newp[1] or type(got) is not type(newp[1]):
                    problems.append("%s 的值没有逐字搬移：%r → %s = %r" % (k, newp[1], newp[0], got))
            continue
        if want is not MISS and av is MISS and bv == want and type(bv) is type(want):
            continue
    problems.append("白名单外的改动：%s  %r → %r"
                    % (k, None if av is MISS else av, None if bv is MISS else bv))

if problems:
    for x in problems:
        sys.stderr.write("      " + x + "\n")
    sys.exit(1)
sys.exit(0)
PY
}

# --apply：四道验收，缺一不可。每一道挡的是不同的错，按「改写可能出的 6 种错」
# 逐项对照裁剪出来的：
#   ① 白名单 diff   挡 ③ 顺手弄坏别的、⑤ 跨段污染，并对 ② 值搬错精确到值
#   ② check         挡语法与字段合法性
#   ③ 沙箱起得来    挡 ④ tag 引用错（check 实测放过）
#   ④ 发现层归零    挡 ① 漏改（漏改不产生 diff、check 沉默、沙箱照样起得来）
# 只作用于 $CFG。--config 是只读审查专用，两者互斥。
_cfg_apply() {
  local cfg="$CFG"

  # 版本闸门：http_client 是 1.14.0 才有的键，改到老内核上等于把配置写成它不认识
  # 的样子。发现层在老内核上会降级成只用 check 档，但改写没有降级余地，直接拒。
  local kver
  kver=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
  [ -n "$kver" ] || die "取不到内核版本，--apply 拒绝在未知版本上改写配置"
  if ver_gt 1.14.0 "$kver"; then
    die "内核 ${kver} 还不认识 http_client / store_dns（1.14.0 起才有），--apply 拒绝改写"
  fi

  # 逐条列出将改哪些键、各几处——三条规则同时命中时，人要看得出改了什么。
  step "将改写的规则"
  local hits total=0 hid hn hpat
  hits=$(_cfg_auto_hits "$cfg")
  while IFS="$(printf '\t')" read -r hid hn hpat; do
    [ -n "$hid" ] || continue
    printf '      %-20s %s 处   %s\n' "$hid" "$hn" "$hpat"
    total=$((total + hn))
  done <<HITS
$hits
HITS
  if [ "$total" = 0 ]; then
    ok "无需改写：三条规则命中 0 处，${cfg} 一字未动"
    return 0
  fi

  local new; new=$(mktmp)
  _cfg_migrate "$cfg" "$new" || die "改写失败"
  json_valid "$new" || die "改写结果不是合法 JSON"

  step "验收 1/4　白名单结构 diff"
  if _cfg_whitelist_diff "$cfg" "$new"; then
    ok "改动只落在规则表列出的路径上，值逐字搬移"
  else
    die "改写越界，拒绝落地（${cfg} 一字未动）"
  fi

  step "验收 2/4　sing-box check"
  local chk; chk=$(mktmp)
  if "$BIN" check -c "$new" >"$chk" 2>&1; then
    ok "新配置通过 check"
  else
    sed 's/^/      /' "$chk" >&2
    die "新配置没通过 check，拒绝落地（${cfg} 一字未动）"
  fi

  step "验收 3/4　沙箱起得来"
  local passed=4 runlog=""
  if _sb_udp_alive; then
    local port wd sbcfg
    port=$(_sb_free_port 10900)
    [ -n "$port" ] || die "10900 起的 200 个端口全被占用，找不到可用的沙箱端口"
    wd=$(mktmpd)
    sbcfg="$wd/config.json"
    _sb_derive_config "$new" "$sbcfg" "$port" "$wd" || die "派生沙箱配置失败"
    json_valid "$sbcfg" || die "派生出来的沙箱配置不是合法 JSON"
    _sb_probe_socks "$BIN" "$sbcfg" "$port" "$wd" \
      || die "沙箱验收未过，拒绝落地（${cfg} 一字未动）"
    runlog="$wd/run.log"        # 顺手收割：第 4 道把它当 D 路输入
  else
    # 沙箱的 cache.db 是空的，remote 规则集要现下一遍——没网这一道跑不了。
    # 这条规则下第 3 道的边际价值本来就最低：它唯一独占的错是 tag 引用写错，
    # 而内联 http_client 没有 tag 引用，从源头就免疫了。
    passed=3
    warn "网络不通，第 3 道（沙箱）跳过：本次只过了 3/4 道（1、2、4）"
  fi

  step "验收 4/4　重跑发现层归零"
  # 在**新配置**上跑，落地之前。这才是闸门——漏改不产生 diff、check 沉默、
  # 沙箱照样起得来，前三道全漏，只有这一道抓得住。
  local left rows4; rows4=$(mktmp)
  # 审不了就不能落地：这一道是漏改的唯一防线，跳过它等于四道只剩三道，
  # 而漏改恰恰是另外三道全挡不住的那一型。
  _cfg_audit "$new" "$runlog" "$([ -n "$runlog" ] && echo 1 || echo 0)" >"$rows4" \
    || die "第 4 道没做成（审不了改写结果），拒绝落地（${cfg} 一字未动）"
  # 归零的判据是规则表自己的谓词：三条 auto 规则在新配置上的命中数之和必须是 0。
  left=$(_cfg_auto_hits "$new" | awk -F'\t' '{n += $2} END {print n + 0}')
  if [ "${left:-0}" != 0 ]; then
    die "改写后仍有 ${left} 处规则命中，拒绝落地（${cfg} 一字未动）"
  fi
  ok "新配置里三条规则的命中数已归零"

  #--- 落地 -------------------------------------------------------------
  # 四道都过了才走到这里。-n 在这一步收手：前面那四道是只读的，干跑照样走完，
  # 所以 `-n config audit --apply` 是一次完整的预演 —— 它把「会改成什么、四道过不过」
  # 全都说清楚了，只是不写盘。
  if [ "$DRY" = 1 ]; then
    dim "[dry-run] 备份现有配置、清理到最近 10 份、写入 ${cfg} 并重启服务"
    info "四道验收已跑完（${passed}/4 道），但没有改动 ${cfg}（-n）"
    return 0
  fi

  # 默认 y：--apply 这个 flag 本身就是意图表达，而 ask 在 -y / 非交互下取的是
  # **默认值**（不是「一律同意」）——默认写 n 的话，自动化场景就永远落不了地。
  # 留这一问是为了让交互的人看完四道验收的结果再拍板。
  ask "把上面的改写落到 ${cfg}？" y || { info "未改动 ${cfg}"; return 0; }

  need_root
  backup_config >/dev/null || die "备份失败，未改动 ${cfg}"
  prune_backups 10
  sudo cp "$new" "$cfg" || die "写入失败，${cfg} 可能处于中间态——用 config restore 回退"
  sudo chown root:wheel "$cfg"; sudo chmod 644 "$cfg"
  if [ "$passed" = 4 ]; then
    ok "已落地（四道验收全过）"
  else
    ok "已落地（3/4 道，沙箱未验）"
  fi
  info "回退：$(basename "$0") config restore"
  # 不重启的话内核还在跑旧配置：文件改了，而 err 日志里的 deprecated 告警照样在涨，
  # 「改完了」和「生效了」是两回事。cmd_config restore 也是这么收尾的。
  cmd_restart
  return 0
}

# --deep 用：起一次沙箱跑 $1，把 run.log 的路径与「建链是否成功」打到 stdout。跑不成返回 1（stdout 为空）。
# 沙箱那一套与 --apply 第 3 道同构（_sb_udp_alive → _sb_free_port → _sb_derive_config →
# _sb_probe_socks），不另起一套：D 路的原则是「凡是已经在跑沙箱的地方顺手收割日志」，
# --deep 只是让裸审查也起一次。等待沿用 SANDBOX_WAIT：内核在 Start() 阶段就把 WARN 打完，
# 理论上比建链短，但没有可靠的「打完了」信号。
_cfg_deep_runlog() {
  local cfg="$1" port wd sbcfg
  if ! _sb_udp_alive; then
    warn "网络不通，沙箱日志档（--deep）跳过：本次只有 check / schema / 迁移表三路" >&2
    return 1
  fi
  port=$(_sb_free_port 10900)
  [ -n "$port" ] || { warn "10900 起的 200 个端口全被占用，沙箱日志档（--deep）跳过" >&2; return 1; }
  wd=$(mktmpd)
  sbcfg="$wd/config.json"
  _sb_derive_config "$cfg" "$sbcfg" "$port" "$wd" || { warn "派生沙箱配置失败，沙箱日志档（--deep）跳过" >&2; return 1; }
  json_valid "$sbcfg" || { warn "派生出来的沙箱配置不是合法 JSON，沙箱日志档（--deep）跳过" >&2; return 1; }
  info "沙箱日志档：起一次沙箱收割内核 Start() 阶段的 WARN（最多等 ${SANDBOX_WAIT} 秒）" >&2
  local complete=1
  if ! _sb_probe_socks "$BIN" "$sbcfg" "$port" "$wd" >&2; then
    # 远程规则集下不到时进程死在 initialize rule-set，DNS 那几条 WARN 根本走不到 ——
    # 日志有多少算多少，但要说清它不完整。
    warn "沙箱没建链，沙箱日志档可能不完整（规则集下不到时 DNS 阶段的 WARN 不会出现）" >&2
    complete=0
  fi
  [ -s "$wd/run.log" ] || return 1
  # stdout：<日志路径><TAB><1|0>。第二栏告诉 D 路「没出现的 WARN」能不能当证据
  printf '%s\t%s' "$wd/run.log" "$complete"
}

# 把 _cfg_audit 的 TAB 行渲染成人话，并按 tier 定退出码：
#   0 干净 / 2 有废弃项但内核仍接受 / 1 内核会拒
# 与 cmd_verify 的两档约定同构 —— 1 是「现在就坏」，2 是「将来会坏」。
# $1 配置路径  $2 沙箱日志路径（可空；--deep 把它喂进来）  $3 =1 日志完整（建链成功）
_cfg_audit_report() {
  local cfg="$1" runlog="${2:-}" complete="${3:-0}"
  local rows; rows=$(mktmp)

  local kver
  kver=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
  [ -n "$kver" ] || die "内核不可用（${BIN} 问不出版本号），审查无法进行"
  printf '配置审查：%s   内核 %s\n' "$cfg" "$kver"
  # 迁移表只覆盖到 CFG_TABLE_COVERS 那个 minor。按 minor 比（1.14.9 不提示、1.15.0 提示）：
  # 把 patch 位抹成 0 再用三段的 ver_gt。只提示，退出码不看它。
  local kmm; kmm=$(printf '%s' "$kver" | cut -d. -f1,2)
  if ver_gt "${kmm}.0" "$CFG_TABLE_COVERS"; then
    warn "迁移表只覆盖到 ${CFG_TABLE_COVERS}，内核 ${kver} 新增的废弃项请用 --deep 或查 https://sing-box.sagernet.org/deprecated/"
  fi
  # 这里是用户直接问的，「审不了」必须说出来 —— 不能拿一个没做成的检查
  # 去打印「没有废弃项」。
  _cfg_audit "$cfg" "$runlog" "$complete" >"$rows" \
    || die "审查没做成（读不到 ${cfg}，或内核跑不起来）—— 这不代表配置没问题"

  # 渲染交给 python：同一问题的多处合并成表格一行（21 条 download_detour 是一行「21 处」），
  # 表格四列只放看得懂的东西——结论 / 在哪 / 谁发现的 / 怎么办；原委、链接、建议片段按编号
  # 放到「详情」。列宽按东亚宽度对齐，bash 里算不了。
  local tbl det sum; tbl=$(mktmp); det=$(mktmp); sum=$(mktmp)
  python3 - "$rows" "$tbl" "$det" "$sum" "$DOC_FINDINGS_URL" <<'PY'
import re, sys, unicodedata
rows_path, tbl_path, det_path, sum_path, doc_url = sys.argv[1:6]
TIER = {"removed": "起不来", "deprecated": "将来会坏", "notice": "提示"}
SRC = (("check", "check"), ("schema", "schema"), ("table", "表"), ("run", "run"))

def dec(sn):
    out, i = [], 0
    while i < len(sn):
        c = sn[i]
        if c == "\\" and i + 1 < len(sn):
            n = sn[i + 1]
            out.append({"n": "\n", "t": "\t", "\\": "\\"}.get(n, "\\" + n)); i += 2
        else:
            out.append(c); i += 1
    return "".join(out)

def w(t):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
def pad(t, n):
    return t + " " * max(0, n - w(t))

rows = []
for line in open(rows_path):
    f = line.rstrip("\n").split("\t")
    if len(f) < 3:
        continue
    while len(f) < 8:
        f.append("")
    rows.append(dict(tier=f[0], src=f[1], path=f[2], desc=f[3], url=f[4], snippet=dec(f[5]), action=f[6], doc=f[7]))
# --deep 撤掉的 notice 单独成行说明，不进表格、不进详情、不进计数
dropped = [r for r in rows if r["tier"] == "dropped"]
rows = [r for r in rows if r["tier"] != "dropped"]

# 同一问题合并：结论 + 原委 + 链接 + 怎么办 相同就是同一项
groups = []
for r in rows:
    key = (r["tier"], r["desc"], r["url"], r["action"], r["doc"])
    g = next((g for g in groups if g["key"] == key), None)
    if g is None:
        g = {"key": key, "tier": r["tier"], "desc": r["desc"], "url": r["url"], "action": r["action"],
             "doc": r["doc"], "paths": [], "src": set(), "snips": []}
        groups.append(g)
    g["paths"].append(r["path"])
    g["src"].update(x for x in r["src"].split("+") if x)
    if r["snippet"]:
        g["snips"].append((r["path"], r["snippet"]))

def natkey(p):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", p)]

def squeeze(paths):
    """路径列：≥3 处且只差一个下标、下标连续 → prefix[a…b]suffix；≤3 处全列；再多列两个加「等 N 处」。"""
    paths = sorted(set(paths), key=natkey)
    if len(paths) >= 3:
        m = [re.match(r"^(.*?)\[(\d+)\](.*)$", p) for p in paths]
        if all(m) and len(set(x.group(1) for x in m)) == 1 and len(set(x.group(3) for x in m)) == 1:
            idx = sorted(int(x.group(2)) for x in m)
            if idx == list(range(idx[0], idx[0] + len(idx))):
                return "%s[%d…%d]%s" % (m[0].group(1), idx[0], idx[-1], m[0].group(3)), True
    if len(paths) <= 3:
        return " ".join(paths), False
    return "%s %s 等 %d 处" % (paths[0], paths[1], len(paths)), False

lines = []
for i, g in enumerate(groups, 1):
    where, _ = squeeze(g["paths"])
    n = len(set(g["paths"]))
    act = g["action"] or ""
    if n > 1:
        act = (act + "（%d 处）" % n) if act else "%d 处" % n
    lines.append([str(i), TIER.get(g["tier"], g["tier"]), where,
                  " ".join(name for k, name in SRC if k in g["src"]), act])

with open(tbl_path, "w") as out:
    if lines:
        head = ["#", "结论", "在哪", "谁发现的", "怎么办"]
        widths = [max(w(x[c]) for x in [head] + lines) for c in range(5)]
        out.write(" " + "  ".join(pad(head[c], widths[c]) for c in range(5)).rstrip() + "\n")
        for x in lines:
            out.write(" " + "  ".join(pad(x[c], widths[c]) for c in range(5)).rstrip() + "\n")
    if dropped:
        # 撤了 0 条不打；有就说清撤了哪几处、凭什么撤
        out.write("\n" if lines else "")
        out.write(" --deep 已排除 %d 条：%s\n" % (len(dropped), "；".join("%s %s" % (r["path"], r["desc"]) for r in dropped)))

with open(det_path, "w") as out:
    if groups:
        out.write("详情\n")
    for i, g in enumerate(groups, 1):
        out.write(" %d  %s\n" % (i, g["desc"]))
        if g["url"]:
            out.write("    %s\n" % g["url"])
        if g["doc"] and doc_url:
            out.write("    解读：%s#%s\n" % (doc_url, g["doc"]))
        paths = sorted(set(g["paths"]), key=natkey)
        if len(paths) > 1:
            out.write("    位置：%s\n" % " ".join(paths))
        for path, sn in g["snips"]:
            out.write("    建议写法（按 v1.14.0 源码语义推导，未经行为验证，需人工核对）%s：\n"
                      % ("，针对 " + path if len(paths) > 1 else ""))
            for l in sn.split("\n"):
                out.write("      %s\n" % l)

cnt = {"removed": 0, "deprecated": 0, "notice": 0}
spots = {"removed": 0, "deprecated": 0, "notice": 0}
for g in groups:
    cnt[g["tier"]] += 1
    spots[g["tier"]] += len(set(g["paths"]))
def n_(tier):
    return "%d 项" % cnt[tier] + ("（共 %d 处）" % spots[tier] if spots[tier] > cnt[tier] else "")
with open(sum_path, "w") as out:
    if cnt["removed"]:
        out.write("bad\t%s起不来：内核拒绝这份配置（已移除的字段或无效值）\n" % n_("removed"))
    elif cnt["deprecated"]:
        tail = "，%d 条提示" % cnt["notice"] if cnt["notice"] else ""
        out.write("warn\t%s将来会坏：现在能跑，下个大版本内核会拒收%s\n" % (n_("deprecated"), tail))
    elif cnt["notice"]:
        out.write("ok\t没有废弃项，也没有未知键（%d 条提示见上）\n" % cnt["notice"])
    else:
        out.write("ok\t没有废弃项，也没有未知键\n")
PY
  [ -s "$tbl" ] && { echo; cat "$tbl"; }
  echo
  local level msg
  IFS="$(printf '\t')" read -r level msg <"$sum"
  case "$level" in bad) bad "$msg" ;; warn) warn "$msg" ;; *) ok "$msg" ;; esac
  [ -s "$det" ] && { echo; cat "$det"; }

  # 退出码按档位：只要有 removed 就 1，否则有 deprecated 就 2；notice 不算
  local n_removed n_deprecated
  n_removed=$(awk -F'\t' '$1=="removed"{n++} END{print n+0}' "$rows")
  n_deprecated=$(awk -F'\t' '$1=="deprecated"{n++} END{print n+0}' "$rows")
  [ "$n_removed" -gt 0 ] && return 1
  [ "$n_deprecated" -gt 0 ] && return 2
  return 0
}

cmd_config() {
  require_installed
  case "${1:-show}" in
    show)   sudo cat "$CFG" ;;
    backup) need_root; acquire_lock; backup_config >/dev/null || die "备份失败"
            prune_backups 10; ok "已备份" ;;
    list)   ls -1t "$CFG".*.bak 2>/dev/null | sed 's/^/      /' || info "无备份" ;;
    diff)
      local b="${2:-}"
      [ -n "$b" ] || b=$(ls -1t "$CFG".*.bak 2>/dev/null | head -1)
      [ -n "$b" ] && [ -f "$b" ] || die "无可比较的备份"
      info "对比：$b → 当前"
      sudo diff -u "$b" "$CFG" || true ;;
    restore)
      need_root; acquire_lock
      local b="${2:-}"
      [ -n "$b" ] || b=$(ls -1t "$CFG".*.bak 2>/dev/null | head -1)
      [ -n "$b" ] && [ -f "$b" ] || die "无可恢复的备份"
      info "将恢复：$b"
      ask "确认？" n || return 0
      sudo "$BIN" check -c "$b" >/dev/null 2>&1 || warn "该备份未通过校验，恢复后可能起不来"
      backup_config >/dev/null || die "备份现有配置失败，未执行恢复"
      sudo cp "$b" "$CFG" || die "恢复失败，$CFG 未改动"
      sudo chown root:wheel "$CFG"; sudo chmod 644 "$CFG"
      ok "已恢复"; cmd_restart ;;
    audit)
      shift
      # 参数解析。⚠️ 每个 shift 2 之前都要确认 $2 存在：shift 2 在参数不够时
      # 返回 1 且**不消耗任何参数**，这个 while 会原地死转。
      local a_cfg="" a_deep=0 a_apply=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --config) [ -n "${2:-}" ] || die "--config 需要参数，如 --config ./config.json"
                    a_cfg="$2"; shift 2 ;;
          --apply)  a_apply=1; shift ;;
          --deep)   a_deep=1; shift ;;
          *) die "config audit: 未知参数 $1（--config <path> | --apply | --deep）" ;;
        esac
      done
      # 互斥：--apply 的回退点是 backup_config，那套只认 $CFG。允许 --apply --config
      # 就等于要么新造一套备份机制，要么让改写落在一个没有回退点的文件上。
      if [ "$a_apply" = 1 ] && [ -n "$a_cfg" ]; then
        die "--apply 只作用于 ${CFG}，不能与 --config 同用（--config 是只读审查专用）"
      fi
      if [ "$a_apply" = 1 ]; then
        [ -f "$CFG" ] || die "找不到配置：$CFG"
        _cfg_audit_report "$CFG" || true
        _cfg_apply
        return $?
      fi
      # --config 指向任意文件，这正是它存在的理由：审查不需要 live 配置、不需要
      # root，测试才能全离线。不给就审 $CFG（644，普通用户读得到）。
      [ -n "$a_cfg" ] || a_cfg="$CFG"
      [ -f "$a_cfg" ] || die "找不到配置：$a_cfg"
      # --deep：沙箱日志档（D 路）。裸审查是毫秒级离线的，这一档要起沙箱、要网络（冷
      # cache 得把远程规则集全下一遍），所以是 opt-in。无网络就降级并明说，退出码按 A/B/C。
      local runlog="" complete=0 deep_out
      if [ "$a_deep" = 1 ]; then
        deep_out=$(_cfg_deep_runlog "$a_cfg") || deep_out=""
        runlog=$(printf '%s' "$deep_out" | cut -f1)
        complete=$(printf '%s' "$deep_out" | cut -f2)
      fi
      _cfg_audit_report "$a_cfg" "$runlog" "${complete:-0}"
      return $? ;;
    *) die "config: 未知子命令 $1（show|backup|list|diff|restore|audit）" ;;
  esac
}

#=======================================================================
# 服务控制
#=======================================================================
# --dry-run 一律用「动手前打印计划再 return」，不要逐条包 run()。
# run() 在 DRY 下返回 0 却什么也没做，而这些命令后面全都要读真实状态来判断：
#   cmd_start  bootstrap 空转 → sleep 2 后 running 为假 → 报「启动后进程未出现」
#   cmd_update download 空转 → tar 读不到包 → die
#   cmd_update → cmd_restart 空转返回 0 → _sb_health 读真实状态 → 误判 → **触发回滚**
# 所以早退点一律选在「已经把该查的都查完、但还没动系统」的那一刻。
cmd_start() {
  require_installed; need_root; acquire_lock
  [ -f "$PLIST" ] || die "未安装服务 —— 先运行 install"
  [ "$DRY" = 1 ] && { dim "[dry-run] launchctl enable + bootstrap system $PLIST"
                      dim "[dry-run] 起来后若 DNS 不在代理模式，会问要不要设为 $PROXY_DNS"; return 0; }
  if running; then warn "已在运行"; return 0; fi
  sudo launchctl enable "$LABEL" 2>/dev/null || true
  if sudo launchctl bootstrap system "$PLIST" 2>&1 | sed 's/^/    /'; then
    sleep 2
    if running; then
      ok "已启动"
      # 之前停服时还原过 DNS 的话，这里要设回去，否则查询不进 TUN 会被投毒
      if ! dns_is_proxy_mode; then
        warn "系统 DNS 不在代理模式 —— 查询可能不进 TUN 而被明文投毒"
        if ask "把 DNS 设为 ${PROXY_DNS}？" y; then
          [ -f "$DNS_BACKUP" ] || dns_backup_save
          dns_apply_proxy; ok "已设置"
        fi
      fi
    else
      bad "启动后进程未出现"; sudo tail -20 "$ERRFILE" 2>/dev/null | sed 's/^/      /'; return 1
    fi
  else
    bad "加载失败"; info "跑 $(basename "$0") doctor"; return 1
  fi
}

cmd_stop() {
  local restore_dns="" dns_target="backup"
  while [ $# -gt 0 ]; do
    case "$1" in
      --restore-dns) restore_dns=1; shift ;;
      --keep-dns)    restore_dns=0; shift ;;
      --dns)         dns_target="${2:-}"; [ -n "$dns_target" ] || die "--dns 需要参数：dhcp | backup | <地址>"
                     restore_dns=1; shift 2 ;;
      --dns-dhcp)    dns_target=dhcp; restore_dns=1; shift ;;
      *) die "stop: 未知参数 $1（--restore-dns | --keep-dns | --dns dhcp|backup|<地址> | --dns-dhcp）" ;;
    esac
  done
  need_root
  acquire_lock
  [ "$DRY" = 1 ] && { dim "[dry-run] launchctl bootout $LABEL"
                      dim "[dry-run] 随后按 --restore-dns / --keep-dns / --dns 处理系统 DNS"; return 0; }
  sudo launchctl bootout "$LABEL" 2>/dev/null
  sleep 1
  if running; then
    warn "仍有进程在跑（可能是 debug 或手动前台实例，不受 launchd 管辖）"
    dim "回那个终端 Ctrl-C；不要 kill -9"
  else
    ok "已停止"
  fi
  dim "只对本次开机有效；跨重启停用用 disable"
  _maybe_restore_dns "$restore_dns" "$dns_target"
}

# 停服后按需还原 DNS
#   $1: 1=还原 0=保留 空=询问
#   $2: 还原目标 backup|dhcp|<地址>，默认 backup
_maybe_restore_dns() {
  local force="${1:-}" target="${2:-backup}"
  # 早退只管交互询问那一支。用户显式传了 --restore-dns / --dns <地址>，
  # 就算当前不在代理模式也得照做——之前这条早退排在看 $force 之前，
  # 那些参数会被静默吞掉，连一行解释都没有。
  if ! dns_is_proxy_mode; then
    case "$force" in
      1) info "系统 DNS 不在代理模式，但按你的要求仍执行还原" ;;
      *) return 0 ;;
    esac
  fi
  echo
  warn "系统 DNS 仍指向 ${PROXY_DNS} —— 代理已停，这个地址的明文查询在国内会被污染"
  local how
  [ "$target" = dhcp ] && how="交回 DHCP（路由器下发）" || how="按备份回滚，无备份则交回 DHCP"
  case "$force" in
    1) dns_restore "$target" ;;
    0) info "按要求保留当前 DNS 设置" ;;
    *) if ask "还原 DNS？（${how}）" y; then
         dns_restore "$target"
       else
         info "保留当前设置"
         dim "之后可用：$(basename "$0") dns dhcp"
       fi ;;
  esac
}

cmd_restart() {
  require_installed; need_root; acquire_lock
  [ "$DRY" = 1 ] && { dim "[dry-run] launchctl kickstart -k ${LABEL}（失败则 stop --keep-dns + start）"; return 0; }
  if daemon_loaded; then
    if sudo launchctl kickstart -k "$LABEL" 2>/dev/null; then
      sleep 3
      running && ok "已重启" || { bad "重启后未运行"; sudo tail -20 "$ERRFILE" 2>/dev/null | sed 's/^/      /'; return 1; }
    else
      warn "kickstart 失败，改为重新加载"
      # --keep-dns：这是一次「重启」，不是「停服」。不加的话 cmd_stop 会走到
      # _maybe_restore_dns 的询问分支（默认 y）把 DNS 还原成 DHCP，
      # 紧接着 cmd_start 又问要不要设回去——-y 之下来回改两次。
      # _sb_rollback_to_prev 也走这条路径，update 回滚会跟着抖一次 DNS。
      cmd_stop --keep-dns || warn "停止未完全成功，仍尝试启动"
      cmd_start
    fi
  else
    info "服务未加载，直接启动"
    cmd_start
  fi
}

cmd_enable()  {
  need_root; acquire_lock
  [ "$DRY" = 1 ] && { dim "[dry-run] launchctl enable $LABEL"; return 0; }
  sudo launchctl enable "$LABEL" 2>/dev/null && ok "已启用（跨重启生效）" || warn "操作失败"
}
cmd_disable() {
  local restore_dns="" dns_target="backup"
  while [ $# -gt 0 ]; do
    case "$1" in
      --restore-dns) restore_dns=1; shift ;;
      --keep-dns)    restore_dns=0; shift ;;
      --dns)         dns_target="${2:-}"; [ -n "$dns_target" ] || die "--dns 需要参数：dhcp | backup | <地址>"
                     restore_dns=1; shift 2 ;;
      --dns-dhcp)    dns_target=dhcp; restore_dns=1; shift ;;
      *) die "disable: 未知参数 $1（--restore-dns | --keep-dns | --dns dhcp|backup|<地址> | --dns-dhcp）" ;;
    esac
  done
  need_root
  acquire_lock
  [ "$DRY" = 1 ] && { dim "[dry-run] launchctl bootout + disable $LABEL"
                      dim "[dry-run] 随后按 --restore-dns / --keep-dns / --dns 处理系统 DNS"; return 0; }
  sudo launchctl bootout "$LABEL" 2>/dev/null || true
  sudo launchctl disable "$LABEL" 2>/dev/null && ok "已停用（重启后也不会自启）" || warn "操作失败"
  sleep 1
  running && warn "仍有进程在跑（前台实例不受 launchd 管辖，需自行 Ctrl-C）"
  dim "恢复：$(basename "$0") enable && $(basename "$0") start"
  _maybe_restore_dns "$restore_dns" "$dns_target"
}

# logs [n | -f | size | truncate]
#
# 默认那一支先报体积再打日志尾巴：这两个文件只涨不落，而在此之前没有任何命令
# 说过它们有多大。
#
# 读日志不再无条件 sudo —— 那两个文件是 0644，普通用户读得了。之前一律 sudo，
# 结果是没票据时卡在一个看不见的密码提示上（提示被重定向吞掉了）。
cmd_logs() {
  local a="${1:-50}"
  case "$a" in
    truncate) _logs_truncate; return $? ;;
    size)     _logs_size; return 0 ;;
  esac

  [ -f "$LOGFILE" ] || die "日志文件不存在：${LOGFILE}（服务可能从未启动过）"
  if [ "$a" = "-f" ]; then
    _log_cat -f "$LOGFILE"
  elif [[ "$a" =~ ^[0-9]+$ ]]; then
    _logs_size
    echo
    _log_cat "-$a" "$LOGFILE"
  else
    die "logs: 参数应为行数、-f、size 或 truncate"
  fi
}

# tail 一个日志文件。读得动就直接读，读不动才抬 sudo。
_log_cat() {
  local opt="$1" f="$2"
  if [ -r "$f" ]; then tail "$opt" "$f"
  else sudo tail "$opt" "$f"; fi
}

_logs_size() {
  step "日志体积"
  local lo er total
  lo=$(log_bytes "$LOGFILE"); er=$(log_bytes "$ERRFILE")
  total=$(( lo + er ))
  printf '      %-34s %s\n' "$LOGFILE" "$(human_size "$lo")"
  printf '      %-34s %s\n' "$ERRFILE" "$(human_size "$er")"
  printf '      %-34s %s\n' "合计" "$(human_size "$total")"
  log_size_warn || dim "未超过 ${LOG_WARN_MB} MB 的告警阈值"
}

# 原地截断。inode 必须保持不变 —— 见文件上方 log_bytes 那一段的说明。
_logs_truncate() {
  local f before total_before total_after freed
  total_before=$(log_total_bytes)
  [ "$total_before" = 0 ] && { ok "日志本来就是空的，无需回收"; return 0; }

  step "回收日志空间"
  info "当前占用 $(human_size "$total_before")"
  ask "把 ${LOGFILE} 与 ${ERRFILE} 原地清空？（服务不受影响，不重启）" y || { info "已取消"; return 0; }

  for f in "$LOGFILE" "$ERRFILE"; do
    [ -f "$f" ] || continue
    before=$(log_bytes "$f")
    [ "$before" = 0 ] && continue
    # `: > 文件` 是原地截断，inode 不变，launchd 那个 fd 继续有效。
    # 绝不能写成 rm + touch 或 mv —— 换了 inode，守护进程会一直往旧的那个写。
    if [ -w "$f" ]; then
      run ": > '$f'"
    else
      run "sudo sh -c ': > \"$f\"'"
    fi
    info "  $(basename "$f") ← $(human_size "$before")"
  done

  total_after=$(log_total_bytes)
  freed=$(( total_before - total_after ))
  if [ "$DRY" = 1 ]; then
    dim "[dry-run] 以上均未执行"
  elif [ "$total_after" -lt "$total_before" ]; then
    ok "已回收 $(human_size "$freed")，现占用 $(human_size "$total_after")"
  else
    bad "截断没有生效，仍占用 $(human_size "$total_after")"
    return 1
  fi
  return 0
}

#=======================================================================
# update / rollback
#=======================================================================
# 升级的形状是「四个阶段，每个阶段都能回到一个已知可用的状态」：
#   0 预检   不下载。跨 minor 要额外点头——1.11 换过 DNS 格式、1.14 移除了
#            domain_strategy，这类升级不该被 -y 一路放过
#   1 沙箱   装到临时前缀，用新内核跑一份派生配置实测建链。现网服务毫发无损
#   2 升级   此时才动 $BIN。起不来就回滚
#   3 验收   cmd_verify 六步，失败重试一轮再判回滚
#
# 上游 release 的资产列表里没有 checksum 文件（没有 checksums.txt / .sha256 /
# SHA256SUMS），所以完整性只能降级验到「解压出来能跑、且自报架构与本机一致」。
# 这一点会在输出里说明，不装作做过。

# 找一个没人用的本地端口。lsof 要 sudo 又慢，直接 bind 试最准。
_sb_free_port() {
  python3 - "${1:-10900}" <<'PY'
import socket, sys
start = int(sys.argv[1])
for p in range(start, start + 200):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        continue
    finally:
        s.close()
    print(p)
    break
else:
    print("")
PY
}

_sb_port_listening() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
}
# 端口 $1 是不是 **进程 $2** 在听。沙箱探测要用这个而不是上面那个：_sb_free_port 只是
# bind 一下再放手，两个 singbox.sh（audit --deep / --apply 不持锁）同时选端口会拿到同一个；
# 后起的若只看「有人听」，就把先起的监听当成自己的，然后 kill 掉自己那个还没吐日志的沙箱
# ——run.log 空，D 路整个跳过，报告成「没有废弃项」（2026-09-12 并行复现 1/20）。
# lsof 是 macOS 自带的（/usr/sbin）；真内核与假内核（exec python3）都是本进程在听。
_sb_port_listening_by() {
  local lsof; lsof=$(command -v lsof || echo /usr/sbin/lsof)
  [ -x "$lsof" ] || { _sb_port_listening "$1"; return; }     # 没有 lsof 才退回只看端口
  "$lsof" -nP -a -p "$2" -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# 从现网配置派生一份能在沙箱里跑的：现网服务还在跑的时候，第二个实例会在
# tun 设备、mixed 端口、cache_file 三处全部撞车。
#   $1 源配置  $2 目标路径  $3 沙箱端口  $4 沙箱工作目录
# 用 python3 不用 jq：本脚本对 jq 零依赖，而 python3 已经在 check_deps 的必需
# 命令清单里。为了这一处引入新依赖不值当。
_sb_derive_config() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
src, dst, port, workdir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
d = json.load(open(src))

# 沙箱只需要一个能建链的出入口。除了那一个被改到闲置端口的 mixed/socks，
# 其余 inbound 一律丢掉——tun 会去抢虚拟网卡，别的固定端口会跟现网撞。
probe = None
for i in d.get("inbounds", []):
    if i.get("type") in ("mixed", "socks"):
        probe = dict(i); break
if probe is None:
    probe = {"type": "mixed", "tag": "sandbox-in"}
probe["listen"] = "127.0.0.1"
probe["listen_port"] = port
d["inbounds"] = [probe]

exp = d.get("experimental")
if isinstance(exp, dict):
    if isinstance(exp.get("cache_file"), dict):
        exp["cache_file"]["path"] = workdir + "/cache.db"
    # clash_api 是第四处会撞车的监听：external_controller 绑固定端口，
    # external_ui 还会在启动时去下载一份 UI。沙箱一样都用不上，整块删掉。
    exp.pop("clash_api", None)

# log.output 若指向文件，两个实例会往同一个文件里写
log = d.get("log")
if isinstance(log, dict) and log.get("output"):
    log["output"] = workdir + "/sandbox.log"

json.dump(d, open(dst, "w"), ensure_ascii=False, indent=2)
PY
}

# 把新内核装到临时前缀上（沙箱位），回声出装好的路径。
_sb_stage_prefix() {
  local newbin="$1" wd="$2"
  mkdir -p "$wd/bin" || return 1
  install -m 755 "$newbin" "$wd/bin/sing-box" || return 1
  xattr -d com.apple.quarantine "$wd/bin/sing-box" 2>/dev/null || true
  printf '%s' "$wd/bin/sing-box"
}

# 用给定内核跑一份配置，等端口起来，再从 socks 出口实测建链。
#   $1 内核路径  $2 配置路径  $3 端口  $4 工作目录
# 先等端口再 curl：起不来和起来了但代理不通是两种毛病，混在一起就没法判断。
_sb_probe_socks() {
  local bin="$1" cfg="$2" port="$3" wd="$4" pid=0 up=1 rc=1 i ip
  "$bin" run -c "$cfg" -D "$wd" >"$wd/run.log" 2>&1 &
  pid=$!
  # 登记给 cleanup：这一步最长要等 SANDBOX_WAIT 秒，中途 Ctrl-C 的话 $wd 会被删掉，
  # 沙箱进程却还活着——它会让 pgrep -x sing-box 判活，把 running / _sb_health /
  # _stop_all_instances 全带偏，还占着沙箱端口。
  BG_PIDS+=("$pid")
  i=0
  while [ "$i" -lt "$SANDBOX_WAIT" ]; do
    kill -0 "$pid" 2>/dev/null || break        # 进程已经死了，别再干等
    if _sb_port_listening_by "$port" "$pid"; then up=0; break; fi
    i=$((i + 1)); sleep 1
  done
  if [ "$up" != 0 ]; then
    if _sb_port_listening "$port"; then
      bad "沙箱实例没能起来：端口 ${port} 有人在听，但不是沙箱实例（PID ${pid}）——另一个 singbox.sh 正在起沙箱？"
    else
      bad "沙箱实例没能起来（端口 ${port} 始终没有监听）"
    fi
    sed 's/^/      /' "$wd/run.log" >&2
  else
    ip=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:${port}" https://api.ipify.org 2>/dev/null)
    if [ -n "$ip" ]; then ok "沙箱建链成功，出口 ${ip}"; rc=0
    else bad "沙箱建链失败：新内核跑起来了，但代理不通"; fi
  fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  BG_PIDS=()
  return $rc
}

# TUN 路由判据，status / _sb_health / doctor 三处共用。
# auto_route 装的是「分流默认路由」：上半 128.0/1 一整条；下半在老 sing-tun 是整条 0/1，
# sing-box 1.14.0（sing-tun v0.9）起拆成 1/8 2/7 4/6 8/5 16/4 32/3 64/2 七段——刻意避开
# 0.0.0.0/8。只认 0/1 会把七段形状误报成「未接管」（2026-09-10 真机就是这样）；只认 128.0/1
# 又会把「只有上半在、下半七段缺席」判成健康，而那时 1.0.0.0–127.255.255.255 全从 en0 裸奔。
# 所以两半都要：stdout 打 full / upper / lower / none，返回值 0 只有 full。
# ⚠️ 不要 `netstat | grep -q`：grep -q 一命中就退出，netstat 吃 SIGPIPE，pipefail 把 141
# 当整条管道的退出码，「路由在」偶发判成「路由没了」。先收进变量再判。
_tun_route_state() {
  local rt upper=0 lower=0 d
  rt=$(netstat -rn -f inet 2>/dev/null | grep utun)
  printf '%s\n' "$rt" | grep -Eq '^128\.0/1[[:space:]]' && upper=1
  if printf '%s\n' "$rt" | grep -Eq '^0/1[[:space:]]'; then
    lower=1
  else
    lower=1
    for d in '1' '2/7' '4/6' '8/5' '16/4' '32/3' '64/2'; do
      printf '%s\n' "$rt" | grep -Eq "^${d}[[:space:]]" || { lower=0; break; }
    done
  fi
  case "${upper}${lower}" in
    11) echo full;  return 0 ;;
    10) echo upper; return 1 ;;
    01) echo lower; return 1 ;;
    *)  echo none;  return 1 ;;
  esac
}
# 判读文案也统一：$1 是 _tun_route_state 的输出
_tun_route_msg() {
  case "$1" in
    upper) echo "TUN 只接管了一半默认路由：128.0/1 在，下半（0/1 或 1/8…64/2 七段）缺席，1.0.0.0–127.255.255.255 正从 en0 直连" ;;
    lower) echo "TUN 只接管了一半默认路由：下半在，128.0/1 缺席，128.0.0.0–255.255.255.255 正从 en0 直连" ;;
    *)     echo "路由未指向 utun：TUN 未接管" ;;
  esac
}
# 给转储/status 看的路由行：默认网关 + 两半（含七段）
_tun_route_lines() {
  netstat -rn -f inet 2>/dev/null | grep -E '^default|^0/1|^128\.0/1|^(1|2/7|4/6|8/5|16/4|32/3|64/2)[[:space:]]'
}

# 升级后要确认的三件确定性的事：进程活着、TUN 路由在、监听端口在听。
# 三样都不依赖外网，是「起来了没有」最硬的判据——阶段 3 那些依赖公网的检查
# 会抖，这一层不会。
_sb_health() {
  local n=0 port routes
  running && ok "进程存活" || { bad "进程未出现"; n=$((n + 1)); }
  # 判据在 _tun_route_state：两半都要指向 utun。TUN 接口自身那条 UH 主机路由只证明
  # 接口建起来了，不证明流量被接管；只有上半在也不算——下半那一半地址从 en0 裸奔，
  # 正是这个功能要挡的故障。
  routes=$(_tun_route_state)
  if [ "$routes" = full ]; then
    ok "TUN 已接管默认路由（两半都指向 utun）"
  else
    bad "$(_tun_route_msg "$routes")"; n=$((n + 1))
  fi
  port=$(sock_addr); port="${port##*:}"
  if _sb_port_listening "$port"; then
    ok "监听端口 ${port} 在听"
  else
    bad "监听端口 ${port} 没有在听"; n=$((n + 1))
  fi
  [ "$n" = 0 ]
}

# 废弃字段的检查已收敛到 _cfg_audit（见 config audit 那一节）。原先这里是一个
# 只 grep check 输出的 _sb_warn_deprecated，连同 install / edit / doctor 三处同构
# 的写法一起，构成一个闭合的盲区：**告警只在 run 时出现，而脚本只在 check 时找
# 告警。**
#
# 上一版的立场是「照打照记，但一个字都不自动改——改写配置需要读 release notes
# 与上游文档，验收标准和『安全升级』完全不是一回事」。本次推翻它，换成：
# 发现层自动跑（只读、毫秒级、不要 root），改写只在 config audit --apply 且只走
# 白名单内的**一条**规则，并以四道机械验收替代「读 release notes」这个人工前提。
# 「读文档」之所以撑不住，是因为它没有失败模式——没读、读错、读了没改，
# 三种情况长得一模一样。

# 阶段 3 的验收。读 cmd_verify 的退出码，不是读布尔值——两者的差别就是这次升级
# 要不要被回滚：
#
#   0  全过，通过
#   2  只有策略档失败（DNS / QUIC / 国内直连）。这些是路由策略问题，换回旧内核一个
#      都修不好，回滚只会把一次本来成功的升级白白撤掉。打条 warn 放行。
#   1  链路档失败。隔几秒再来一轮——第 2/3/5 步依赖 ipinfo.io / cip.cc 这些第三方
#      站点，一次网络抖动不该触发回滚；两轮都败才算数。
_sb_verify_rounds() {
  local i rc
  for i in 1 2; do
    if [ "$i" = 2 ]; then
      warn "第 1 轮验收未通过，${VERIFY_RETRY_WAIT}s 后重试一轮"
      sleep "$VERIFY_RETRY_WAIT"
    fi
    info "验收第 ${i}/2 轮"
    cmd_verify; rc=$?
    [ "$rc" = 0 ] && return 0
    if [ "$rc" = 2 ]; then
      warn "验收只有策略档失败 —— 那是路由策略/环境问题，回滚旧内核换不回来，放行"
      info "新内核保留在位；上面打 ✗ 的几步要自己查配置，跑 rules 与 debug"
      return 0
    fi
  done
  return 1
}

# 换回 $BIN.prev 并重启。$1 是期望回到的版本号，只用于输出。
_sb_rollback_to_prev() {
  local want="${1:-}"
  step "回滚"
  [ -f "$BIN.prev" ] || { bad "没有 ${BIN}.prev，无法回滚 —— 需要手工重装内核"; return 1; }
  sudo mv "$BIN.prev" "$BIN" || { bad "回滚失败：换不回 ${BIN}"; return 1; }
  ok "已换回 ${want:-旧版本}"
  cmd_restart || { bad "回滚后重启失败 —— 跑 $(basename "$0") doctor"; return 1; }
  _sb_health || warn "回滚后健康检查未全过 —— 跑 $(basename "$0") doctor"
  return 0
}

cmd_update() {
  require_installed; need_root; acquire_lock

  #--- 阶段 S：脚本自己 -------------------------------------------------
  # 先脚本后内核。SB_SELF_UPDATED=1 是 exec 进来的新进程，整段跳过防死循环。
  if [ "${SB_SELF_UPDATED:-0}" = 1 ]; then
    dim "脚本已在本次升级中更新过，跳过阶段 S"
  else
    _self_update
  fi

  #--- 阶段 0：预检（不下载）--------------------------------------------
  step "阶段 0/3　预检"
  local cur new arch
  cur=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
  info "当前：${cur:-未知}"
  new=$(latest_version) || die "无法获取最新版本（GitHub 与所有镜像均不可达）；可用 install --version 手动指定"
  info "最新：$new"
  [ "$cur" = "$new" ] && { ok "已是最新"; return 0; }
  ask "升级到 ${new}？" y || return 0

  # 跨 minor 单独再拦一道，默认 n：-y 会取默认值，于是非交互模式下跳过而不是闷头升。
  if [ "${cur%.*}" != "${new%.*}" ]; then
    warn "跨 minor 升级：${cur} → ${new}"
    info "这类升级历史上移除过配置字段（1.11 换 DNS 格式、1.14 移除 domain_strategy）"
    info "沙箱阶段会实测配置，但 TUN 与系统路由相关的回归只有升级之后才暴露"
    ask "确认继续？" n || {
      info "已跳过。要升的话去掉 -y 交互确认，并先读一遍 release notes"
      return 0
    }
  fi

  arch=$(detect_arch)
  [ -n "$arch" ] || die "不支持的架构：$(uname -m)"

  # 早退点选在这里：阶段 0 该查的都查完了（版本、跨 minor 确认、架构），但一个字节都还没下。
  # dry-run 最有用的信息恰恰是「当前什么版本、要升到什么、接下来会做哪几步」。
  if [ "$DRY" = 1 ]; then
    dim "[dry-run] 下载 sing-box-${new}-darwin-${arch}.tar.gz"
    dim "[dry-run] 阶段 1 沙箱：临时前缀实跑新内核 + check -c 当前配置 + socks 建链（现网不受影响）"
    dim "[dry-run] 阶段 2 升级：$BIN → ${BIN}.prev，装入 v${new}，重启并做健康检查"
    dim "[dry-run] 阶段 3 验收：跑 verify，链路档失败才回滚，策略档失败放行"
    info "以上均未执行。真正升级去掉 -n。"
    return 0
  fi

  local tmpd; tmpd=$(mktmpd)
  local tarball="sing-box-${new}-darwin-${arch}.tar.gz"
  local want_sha; want_sha=$(asset_digest "$new" "$tarball") || want_sha=""
  if [ -n "$want_sha" ]; then dim "校验值来自 GitHub API：${want_sha}"
  else warn "取不到该 asset 的 sha256 —— 本次不做完整性校验"; fi
  download "$tmpd/sb.tar.gz" "$GH_DL/v${new}/${tarball}" "内核 v$new" "$want_sha" \
    || die "下载失败"
  tar xzf "$tmpd/sb.tar.gz" -C "$tmpd" || die "解压失败"
  local newbin="$tmpd/sing-box-${new}-darwin-${arch}/sing-box"
  [ -f "$newbin" ] || die "压缩包结构异常"

  #--- 阶段 1：沙箱（现网服务继续跑，完全不受影响）------------------------
  step "阶段 1/3　沙箱验证（现网服务不受影响）"
  local wd stage vout chk port sbcfg
  wd=$(mktmpd)
  stage=$(_sb_stage_prefix "$newbin" "$wd") || die "沙箱安装失败"

  vout=$("$stage" version 2>&1) || {
    bad "新内核跑不起来："
    printf '%s\n' "$vout" | sed 's/^/      /' >&2
    die "阶段 1 失败，现网未被触碰（\$BIN 仍是 ${cur}）"
  }
  ok "新内核可执行：$(printf '%s' "$vout" | head -1)"

  # 完整性校验已经在 download 里按 GitHub API 的 asset digest 做过了（见 asset_digest）。
  # 这里再验一次架构，是因为 sha256 只能证明「文件没被改」，不能证明「下对了平台」。
  if printf '%s' "$vout" | grep -q "darwin/${arch}"; then
    ok "架构匹配：darwin/${arch}"
  else
    die "架构不匹配：期望 darwin/${arch}，实际 $(printf '%s' "$vout" | sed -n 's/.*\(darwin\/[a-z0-9]*\).*/\1/p' | head -1)"
  fi
  dim "sha256 已在下载阶段比对（校验值取自 GitHub API 的 asset digest）"

  chk=$(mktmp)
  if sudo "$stage" check -c "$CFG" >"$chk" 2>&1; then
    ok "新内核校验当前配置通过"
  else
    bad "新内核不接受当前配置："
    sed 's/^/      /' "$chk" >&2
    die "阶段 1 失败，现网未被触碰（\$BIN 仍是 ${cur}）"
  fi
  _cfg_audit_notice "$CFG"

  # check -c 只看语法与字段合法性：字段还在、语义变了它照样过。所以还要实跑一次。
  port=$(_sb_free_port 10900)
  [ -n "$port" ] || die "10900 起的 200 个端口全被占用，找不到可用的沙箱端口"
  sudo cat "$CFG" > "$wd/live.json" 2>/dev/null || die "读不到当前配置 ${CFG}"
  sbcfg="$wd/config.json"
  _sb_derive_config "$wd/live.json" "$sbcfg" "$port" "$wd" || die "派生沙箱配置失败"
  json_valid "$sbcfg" || die "派生出来的沙箱配置不是合法 JSON"
  info "沙箱配置：只留一个 mixed（改到 ${port}）、去掉 clash_api、cache_file 指向临时目录"
  _sb_probe_socks "$stage" "$sbcfg" "$port" "$wd" \
    || die "阶段 1 失败，现网未被触碰（\$BIN 仍是 ${cur}）"

  #--- 阶段 2：升级（此时才动现网）----------------------------------------
  step "阶段 2/3　升级现网"
  sudo cp "$BIN" "$BIN.prev" || die "备份旧版失败"
  sudo install -m 755 "$newbin" "$BIN" || { sudo mv "$BIN.prev" "$BIN"; die "安装失败，已回滚"; }
  sudo xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
  ok "已装入 v${new}（旧版备份在 ${BIN}.prev）"

  if ! sudo "$BIN" check -c "$CFG" >"$chk" 2>&1; then
    bad "现网位上校验配置失败："
    sed 's/^/      /' "$chk" >&2
    _sb_rollback_to_prev "$cur"
    return 1
  fi

  # ⚠️ cmd_restart 的返回值必须看。之前这里是裸调用，「起不来」这条路径
  # 从来没有被走到过，而那恰恰是最需要回滚的时刻。
  if ! cmd_restart; then
    bad "新内核重启失败"
    _sb_rollback_to_prev "$cur"
    return 1
  fi
  if ! _sb_health; then
    bad "升级后健康检查未通过"
    _sb_rollback_to_prev "$cur"
    return 1
  fi

  #--- 阶段 3：验收 -------------------------------------------------------
  step "阶段 3/3　功能验收"
  if ! _sb_verify_rounds; then
    bad "功能验收两轮都没过"
    _sb_rollback_to_prev "$cur"
    return 1
  fi

  # 内核版本变了，废弃面和 schema 跟着变 —— 这是最该重查一次配置现代性的时刻，
  # 也正是「21 条 download_detour 悄悄变成历史」这件事的成因。只报不改，且**不**
  # 影响 update 的退出码与回滚判定：配置将来会坏，不等于这次升级失败了。
  # 阶段 1 的沙箱是用新内核跑的，它的 run.log 顺手喂给 D 路——Start() 阶段的 WARN
  # 只有实跑才有，这里不多起一次沙箱。
  _cfg_audit_notice "$CFG" "$wd/run.log"
  # 规则集合并匹配语义在 1.14.0 纠正（changelog 注 14）。它没有可离线判定的谓词，
  # 每次审查都打就是噪音，只在跨过 1.14.0 的这一次升级里说一遍。
  if ver_gt 1.14.0 "$cur" && ! ver_gt 1.14.0 "$new"; then
    warn "1.14.0 纠正了规则集的合并匹配语义：只有「单条 default 规则且无 invert」的规则集才并进引用它的规则，其余按「任一条自行命中」处理。靠旧行为才生效的规则要人工核对：https://sing-box.sagernet.org/changelog/#1140"
  fi

  ok "升级完成：${cur} → ${new}"
  info "旧版本保留在 ${BIN}.prev，下一次 update 才会覆盖它"
  info "事后才发现问题：$(basename "$0") rollback"
  warn "srs 规则集有格式版本，接着跑：$(basename "$0") rules"
  return 0
}

# 把回滚从「升级过程中的一个分支」变成任何时候都能按的按钮：当时一切正常、
# 半小时后才发现某个网站进不去，靠的就是这条。只保留一份 .prev，只能退一步。
cmd_rollback() {
  require_installed; need_root; acquire_lock
  step "回滚到上一个内核"
  [ -f "$BIN.prev" ] \
    || die "没有 ${BIN}.prev —— 没有可回滚的上一个版本（只保留一份，且 update 成功之后才会有）"

  local cur prev
  cur=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
  prev=$("$BIN.prev" version 2>/dev/null | head -1 | awk '{print $3}')
  info "当前：${cur:-未知}"
  info "回到：${prev:-未知}"
  ask "确认回滚？" y || return 0

  if [ "$DRY" = 1 ]; then
    dim "[dry-run] mv ${BIN}.prev → ${BIN}，重启，再跑一遍 verify 验收"
    dim "[dry-run] 有 ${LAUNCHER}.prev 的话，singbox 命令一并退回上一版"
    info "以上均未执行。"
    return 0
  fi

  sudo mv "$BIN.prev" "$BIN" || die "回滚失败：换不回 ${BIN}"
  sudo xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
  ok "已换回 ${prev:-旧版本}"

  # 内核与启动器各有各的 .prev，退路是独立的。只退内核而不退命令，下次跑的仍是
  # 新脚本 —— 等于只退了一半，而终端上看不出来。
  if [ -f "$LAUNCHER.prev" ]; then
    if sudo mv -f "$LAUNCHER.prev" "$LAUNCHER"; then
      ok "singbox 命令已退回上一版（${LAUNCHER}）"
    else
      warn "内核已退回，但换不回 ${LAUNCHER} —— 手工：sudo mv ${LAUNCHER}.prev ${LAUNCHER}"
    fi
  else
    info "没有 ${LAUNCHER}.prev —— singbox 命令没有退路，本次只退了内核"
  fi

  cmd_restart || die "回滚后重启失败 —— 跑 $(basename "$0") doctor"
  _sb_health || warn "健康检查未全过"

  step "验收"
  if _sb_verify_rounds; then
    ok "回滚完成，功能验收通过"
    return 0
  fi
  bad "已换回 ${prev:-旧版本}，但功能验收没过 —— 问题可能不在内核版本上，跑 $(basename "$0") doctor"
  return 1
}

#=======================================================================
# dns
#=======================================================================
cmd_dns() {
  # status 是只读的，不占锁；其余几支都会改系统 DNS，而 dns_backup_save 是
  # 「清空再逐行 append」的非原子写，并发下能读到半份文件。
  case "${1:-status}" in status) ;; *) acquire_lock ;; esac
  case "${1:-status}" in
    status)
      step "系统 DNS 现状"
      _dns_show_current
      echo
      if dns_is_proxy_mode; then
        info "状态：代理模式（指向 ${PROXY_DNS}）"
        running && dim "服务在跑，这是正确状态" \
                || warn "但服务没在跑 —— 明文查询会被污染，建议 dns dhcp"
      else
        info "状态：非代理模式"
        running && warn "服务在跑但 DNS 不是 ${PROXY_DNS} —— 查询可能不进 TUN 被投毒，建议 dns proxy" \
                || dim "服务未运行，这是正确状态"
      fi
      [ -f "$DNS_BACKUP" ] && { echo; info "备份（install 前记录）："; sed 's/^/      /;s/\t/ → /' "$DNS_BACKUP"; }
      ;;
    dhcp)    need_root; step "交回 DHCP（路由器下发）"; dns_restore dhcp ;;
    backup)  need_root; step "按备份还原"; dns_restore backup ;;
    proxy)   need_root; step "设为代理模式"
             [ -f "$DNS_BACKUP" ] || dns_backup_save
             dns_apply_proxy; ok "已设为 ${PROXY_DNS}"; _dns_show_current ;;
    set)
      need_root
      local addr="${2:-}"
      [ -n "$addr" ] || die "dns set 需要地址，如：dns set 223.5.5.5"
      _dns_addr_ok "$addr" || die "地址不合法：${addr}（只接受 IPv4 / IPv6，多个用空格分隔，或字面量 empty）"
      step "设为 $addr"; dns_restore "$addr" ;;
    *) die "dns: 未知子命令 $1（status|dhcp|backup|proxy|set <地址>）" ;;
  esac
}

#=======================================================================
# mirror
#=======================================================================
# 探一个镜像并打印耗时。原本嵌在 cmd_mirror 里，提到顶层是为了让自检第 7 项
# （函数内嵌定义）能真正闭合——那一项之前的正则只匹配 2 空格缩进，
# 抓不到这个 6 空格的，于是恒绿、永远不报。
_mirror_probe_one() {
  local label="$1" u="$2" a b
  a=$(date +%s)
  if probe_url "$u" "$PROBE_TIMEOUT"; then b=$(date +%s)
    printf '      %-34s %s可用%s  %ss\n' "$label" "$C_OK" "$C_N" "$((b-a))"
  else b=$(date +%s)
    printf '      %-34s %s不通%s  %ss\n' "$label" "$C_ERR" "$C_N" "$((b-a))"
  fi
}

cmd_mirror() {
  case "${1:-test}" in
    test)
      step "探测镜像可用性"
      dim "这类站点更替频繁，结果只代表此刻；每个最多等 ${PROBE_TIMEOUT}s"
      local probe_path="$GH_DL/v1.12.0/sing-box-1.12.0-darwin-amd64.tar.gz"
      local m
      _mirror_probe_one "直连 github.com" "$probe_path"
      for m in $(mirror_list); do _mirror_probe_one "$m" "$(mirror_url "$m" "$probe_path")"; done
      echo
      local saved; saved=$(prefs_get mirror 2>/dev/null) || saved=""
      info "当前记住的镜像：${saved:-（无，每次从头试）}"
      [ -n "${SB_MIRRORS:-}" ] && info "环境变量 SB_MIRRORS 已设置，会覆盖上述列表"
      ;;
    set)
      local m="${2:-}"
      [ -n "$m" ] || die "mirror set 需要一个前缀，如：mirror set https://ghfast.top"
      case "$m" in http://*|https://*) ;; *) die "镜像地址必须以 http:// 或 https:// 开头" ;; esac
      info "探测 $m …"
      [ "$DRY" = 1 ] && { dim "[dry-run] 探测后把 $m 写入 $PREFS"; return 0; }
      if probe_url "$(mirror_url "$m" "$GH_DL/v1.12.0/sing-box-1.12.0-darwin-amd64.tar.gz")" "$PROBE_TIMEOUT"; then
        prefs_set mirror "$m" && ok "已固定为首选镜像"
      else
        warn "该镜像此刻探测不通"
        ask "仍然保存？" n && { prefs_set mirror "$m" && ok "已保存"; } || info "未保存"
      fi
      ;;
    reset) [ "$DRY" = 1 ] && { dim "[dry-run] 从 $PREFS 清除 mirror 偏好"; return 0; }
           prefs_unset mirror; ok "已清除镜像偏好，恢复为直连优先 + 内置列表" ;;
    show)
      local saved; saved=$(prefs_get mirror 2>/dev/null) || saved=""
      info "记住的镜像：${saved:-（无）}"
      info "环境变量 SB_MIRRORS：${SB_MIRRORS:-（未设）}"
      info "本次候选顺序：$(mirror_list)"
      ;;
    *) die "mirror: 未知子命令 $1（test|set <url>|show|reset）" ;;
  esac
}

#=======================================================================
# doctor
#=======================================================================
# 判读命中：顶层定义，避免嵌套函数捕获 local 作用域
DOCTOR_FOUND=0
_hit() { bad "$1"; DOCTOR_FOUND=1; }

cmd_doctor() {
  need_root
  step "收集诊断信息"
  # 这份转储里有日志（访问过的域名与出站 tag）、launchctl print、配置校验输出，
  # 不是可以随手丢进 world-readable /tmp 的东西。
  local out; out=$(keep_path "doctor-$(date +%Y%m%d-%H%M%S).txt") || die "无法创建诊断目录"
  {
    echo "===== 脚本 ====="; echo "singbox.sh v$VERSION  prefix=$PREFIX"
    echo "===== 系统 ====="; sw_vers 2>&1; uname -m
    echo; echo "===== 内核 ====="; [ -x "$BIN" ] && "$BIN" version 2>&1 || echo "(未安装)"
    echo; echo "===== 进程 ====="; pgrep -fl sing-box 2>&1 || echo "(未运行)"
    echo; echo "===== launchd ====="; sudo launchctl print "$LABEL" 2>&1 | head -30
    echo; echo "===== plist ====="; ls -l "$PLIST" 2>&1; plutil -lint "$PLIST" 2>&1
    echo; echo "===== 配置校验 ====="; [ -f "$CFG" ] && sudo "$BIN" check -c "$CFG" 2>&1 || echo "(无配置)"
    echo; echo "===== 路由 ====="; _tun_route_lines
    echo; echo "===== utun ====="; ifconfig 2>&1 | grep -A2 utun
    echo; echo "===== IPv6 ====="; ifconfig 2>&1 | grep inet6
    echo; echo "===== 网络服务 ====="
    network_services | while IFS= read -r s; do
      echo "$s | IPv6=$(networksetup -getinfo "$s" 2>/dev/null | awk -F': ' '/^IPv6:/{print $2}') | DNS=$(networksetup -getdnsservers "$s" 2>/dev/null | tr '\n' ' ')"
    done
    echo; echo "===== 端口 ====="; sudo lsof -nP -iTCP -sTCP:LISTEN 2>&1 | grep -E 'sing-box|10808|9090' || echo "(无)"
    echo; echo "===== 冲突进程 ====="
    ps -axo comm= 2>/dev/null | grep -Ei "tailscaled?$|clash|mihomo|surge|openvpn|wireguard|warp-svc" | sort -u || echo "(无)"
    echo; echo "===== DNS ====="; command -v dig >/dev/null && dig +short +time=3 www.google.com 2>&1 | head -3 || echo "(无 dig)"
    echo; echo "===== 日志 ====="; sudo tail -50 "$LOGFILE" 2>&1
    echo; echo "===== 错误日志 ====="; sudo tail -30 "$ERRFILE" 2>&1
  } > "$out" 2>&1
  chmod 600 "$out" 2>/dev/null
  ok "已写入 $out"

  step "自动判读"
  DOCTOR_FOUND=0
  grep -qi "operation not permitted" "$out" && _hit "权限不足：服务须是 LaunchDaemon（/Library/LaunchDaemons），不是 LaunchAgent"
  grep -qi "address already in use" "$out" && _hit "端口被占：见上面端口段，多为别的代理客户端或旧实例"
  grep -qi "failed to download rule.set" "$out" && _hit "规则集下载失败：跑 $(basename "$0") rules"
  grep -q "198\.18\." "$out" && _hit "出现 FakeIP 地址：跑的可能不是这份配置，或嗅探链路断了"
  grep -q "157\.240\." "$out" && _hit "DNS 疑似被投毒：跑 $(basename "$0") syscheck"
  # 这一条**保留**：$out 里含 tail $ERRFILE，也就是内核的运行日志 —— 那是
  # download_detour 这类告警唯一真正出现的地方（check 对它沉默）。四处 grep 里
  # 只有这一处不在盲区里，删掉它等于把唯一的运行时视角也丢了。
  grep -qi "deprecated" "$out" && { warn "存在废弃字段（不阻止启动，但可能静默降级）"; DOCTOR_FOUND=1; }
  # 再加配置视角：运行日志只有跑起来才有，而配置摆在那儿随时可读。
  _cfg_audit_notice "$CFG"
  local rstate; rstate=$(_tun_route_state) || _hit "$(_tun_route_msg "$rstate")"
  [ -f "$PLIST" ] && { plutil -lint "$PLIST" >/dev/null 2>&1 || _hit "plist 语法错误：删掉后重新 install"; }
  grep -q "IPv6=On" "$out" && { warn "有网络服务的 IPv6 未关：跑 $(basename "$0") sysprep"; DOCTOR_FOUND=1; }
  running || _hit "sing-box 未运行"
  # 日志体积单列一条判据：launchd 不轮转，它只涨不落，而且不会自己冒出来。
  log_size_warn && DOCTOR_FOUND=1
  [ "$DOCTOR_FOUND" = 0 ] && ok "未发现已知问题模式"
  local rc=0
  [ "$DOCTOR_FOUND" = 0 ] || rc=1
  echo
  info "把 $out 的内容贴出来即可定位大多数问题"
  warn "贴之前先看一眼：里面有你访问过的域名、节点 tag 与日志"
  return $rc
}

#=======================================================================
# uninstall
#=======================================================================
cmd_uninstall() {
  need_root; acquire_lock
  step "卸载"
  ask "移除服务与内核？配置目录 $ETC 会保留" n || { info "已取消"; return 0; }
  _stop_all_instances
  sudo launchctl disable "$LABEL" 2>/dev/null || true
  sudo rm -f "$PLIST" && ok "服务已移除" \
    || warn "plist 删除失败，$PLIST 仍在（已 disable，重启后不会自启）"
  if ask "同时删除内核 ${BIN}？" n; then sudo rm -f "$BIN" && ok "内核已删除"; fi
  if ask "同时删除配置目录 ${ETC}（含所有备份）？" n; then sudo rm -rf "$ETC" && ok "配置已删除"; fi
  echo
  step "还原系统层设置"
  if dns_is_proxy_mode; then
    if ask "把系统 DNS 交回 DHCP（路由器下发）？" y; then dns_restore dhcp
    else info "保留当前 DNS 设置"; dim "之后可用：$(basename "$0") dns dhcp"; fi
  else
    dim "系统 DNS 未处于代理模式，无需还原"
  fi

  _cleanup_strays

  local v6off=0 svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    [ "$(networksetup -getinfo "$svc" 2>/dev/null | awk -F': ' '/^IPv6:/{print $2}')" = "Off" ] && v6off=1
  done <<< "$(network_services)"
  if [ "$v6off" = 1 ]; then
    if ask "把 IPv6 还原为自动（当初为防泄漏关掉的）？" y; then
      while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        run "sudo networksetup -setv6automatic \"$svc\" 2>/dev/null || true"
        info "  $svc → IPv6 自动"
      done <<< "$(network_services)"
      ok "IPv6 已还原"
    else
      info "保留 IPv6 关闭状态"
      dim "手动还原：sudo networksetup -setv6automatic \"<服务名>\""
    fi
  fi

  # 整个流程的最后一条语句：删掉 install 自动放进去的那个命令。
  # 不问 —— 装的时候没问过，装启动器是 install 的一部分而不是可选项。
  #
  # 跑的就是 $LAUNCHER 自己时也是安全的：rm 是 unlink，不影响本进程已经打开的 fd，
  # 目录项没了而 inode 还在，剩下的语句照常从旧内容里读出来执行。
  if [ -e "$LAUNCHER" ] || [ -e "$LAUNCHER.prev" ]; then
    echo
    if sudo rm -f "$LAUNCHER" "$LAUNCHER.prev"; then
      ok "singbox 命令已移除（${LAUNCHER}）"
    else
      warn "删不掉 ${LAUNCHER} —— 手工：sudo rm -f ${LAUNCHER} ${LAUNCHER}.prev"
    fi
  fi
}

# 清理散落在别处的运行残留。
# 相对路径的 external_ui / cache_file 会落在当时的工作目录，
# 常见于 ~/bin、~ 或你跑脚本时所在的目录。
_cleanup_strays() {
  local dirs=("$(cd "$(dirname "$0")" && pwd)" "$HOME" "$PWD")
  local seen="" d
  local found=()
  for d in ${dirs[@]+"${dirs[@]}"}; do
    # cd 失败时那个元素是空串，不拦住的话下面会去查 /ui 和 /cache.db
    [ -n "$d" ] || continue
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen|$d|"
    [ -d "$d/ui" ] && [ -f "$d/ui/index.html" ] && found+=("$d/ui")
    [ -f "$d/cache.db" ] && found+=("$d/cache.db")
  done
  [ "${#found[@]}" -eq 0 ] 2>/dev/null && return 0

  echo
  warn "发现运行残留（配置里的相对路径落在了工作目录）："
  local x
  for x in ${found[@]+"${found[@]}"}; do
    printf '      %s  (%s)\n' "$x" "$(du -sh "$x" 2>/dev/null | awk '{print $1}')"
  done
  if ask "删除这些残留？" y; then
    # 不给 rm -rf 加 sudo：这些路径来自 $HOME / $PWD / 脚本目录，放大爆炸半径不值当。
    # 删不掉（多半是曾经 sudo 前台跑过、文件属 root）就把命令打出来，决定权交回用户。
    local left=0
    for x in ${found[@]+"${found[@]}"}; do
      [ -n "$x" ] || continue
      if rm -rf "$x" 2>/dev/null; then info "  已删除 $x"
      else left=$((left+1)); warn "  删不掉（可能属 root）：sudo rm -rf '$x'"; fi
    done
    [ "$left" = 0 ] && ok "残留已清理" || warn "$left 项未能删除，见上面的手动命令"
  else
    info "保留"
  fi
  return 0
}

#=======================================================================
# help
#=======================================================================
cmd_help() {
  cat <<EOF
singbox.sh v$VERSION —— sing-box on macOS 全生命周期管理

用法：$(basename "$0") <命令> [参数]

安装与配置
  install [--config <path>] [--version <v>] [--arch <amd64|arm64>] [--force]
                      首次安装：内核 + 系统层准备 + 配置 + 服务
  sysprep             只做系统层准备（换网络、插网卡后修复 IPv6/DNS）
  edit [--editor <cmd>] [--once]
                      改配置（校验 + 备份 + 重启，校验不过不写入）
                      --editor 会被记住，后续 edit 自动使用
                      --once 只用一次不保存；--show-editor 查看；--reset-editor 清除
  config <sub>        show | backup | list | diff [备份] | restore [备份]
                      audit [--config <path>] [--apply] [--deep]
                      配置的废弃与合法性审查（--deep 起沙箱收内核告警，要网络）

运行
  status              服务状态、TUN 路由、监听端口
  start | stop | restart
  enable | disable    开机自启开关（跨重启）
                      stop / disable 支持 --restore-dns | --keep-dns
                                       --dns dhcp|backup|<地址> | --dns-dhcp
  dns <sub>           status | dhcp | backup | proxy | set <地址>
                      系统 DNS 的查看与切换
  logs [n|-f|size|truncate]
                      看日志。默认先报体积再打尾巴；size 只看体积；
                      truncate 原地清空回收空间（inode 不变，服务不受影响、不用重启）
                      launchd 不做日志轮转，这两个文件只涨不落 ——
                      status 与 doctor 超过阈值会点名（默认 64 MB）

检查
  verify              完整验证清单（节点/出口 IP/DNS/IPv6/QUIC/国内直连/局域网）
                      退出码 0 全过；1 链路档失败；2 仅策略档失败
                      链路档：节点链路、兜底出口取不到、两个出口相同、冒出全局 IPv6
                              —— 换内核可能修好，update 只认这一档才回滚
                      策略档：DNS 污染或解析手段全废、QUIC、国内直连、局域网网关、
                              以及参照站点（ipinfo.io / cip.cc）取不到数据
                              —— 路由策略与环境的问题，回滚一个都换不回来
  syscheck            系统层复查（换网络、换硬件后跑）
                      退出码 0 全合格；1 有服务 IPv6 未关、DNS 是内网，或仍有全局 IPv6
  rules               验证规则集 URL 可达。退出码 0 全可达；1 有不可达
  debug               debug 前台跑，看每条连接落在哪个出站
  doctor              收集诊断并自动判读。退出码 0 未发现已知问题；1 命中了判据
                      诊断文件写在 0700 的临时目录里（含域名与日志，贴之前先看一眼）

维护
  update              升级脚本与内核：阶段 S 脚本自更新 → 预检 → 沙箱验证 → 升级 → 验收
                      沙箱阶段用临时前缀实跑新内核，现网服务不受影响；
                      任一阶段失败自动回滚。跨 minor 会额外确认一次
                      验收只认 verify 的链路档（退出 1）才回滚；策略档（退出 2）
                      打条 warn 放行 —— 回滚旧内核修不了路由策略
  rollback            换回上一个内核（update 成功后保留的 .prev）并重新验收
                      .prev 只有 update 会写、只保留一份，只能退一步。
                      install 不碰它（它的临时回滚点放在临时目录里）
  mirror <sub>        test | set <url> | show | reset —— GitHub 下载镜像
  uninstall           卸载

全局参数
  -y, --yes           非交互，所有询问取默认值
  -q, --quiet         只输出警告与错误
  -n, --dry-run       只打印将要执行的操作
      --prefix <dir>  安装前缀（默认 /usr/local）

  -h, --help          本帮助
      --version       脚本版本

环境变量
  SB_MIRRORS          空格分隔的镜像前缀列表，覆盖内置默认
  SB_PREFIX           同 --prefix
  SB_LOGDIR           日志目录（默认 /var/log）。install 时的取值会烧进 plist
  SB_LOG_WARN_MB      日志体积告警阈值，默认 64
  SB_SELF_REPO        脚本自更新的来源仓库（默认 lzyMeta/macos-singbox-client-helper）
  SB_SELF_UPDATED     =1 时 update 跳过阶段 S（阶段 S 自己 exec 时会设）
  SB_LOCK_INHERIT     =1 时沿用 exec 之前那把锁（同一个 PID）
  EDITOR              edit 的默认编辑器（--editor 优先）

示例
  $(basename "$0") install --config ./sing-box-client-config.json
  $(basename "$0") -n install                # 空跑一遍看会做什么
  $(basename "$0") verify
  $(basename "$0") -y update
EOF
}

#=======================================================================
# 参数解析与分发
#=======================================================================
CMD=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1; shift ;;
    -q|--quiet)   QUIET=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    # ⚠️ 这一行重算的四个路径要齐：LAUNCHER 漏了就会出现「内核装进 /opt、
    # 命令装进 /usr/local」。而它们必须与 shift 2 共一行（或紧跟在 || die 那行下面）：
    # 自检第 8 项盯的就是「shift 2 前一行有没有 die 护栏」，拆行会把那道守卫弄丢。
    --prefix)     PREFIX="${2:-}"; [ -n "$PREFIX" ] || die "--prefix 需要参数"
                  BIN="$PREFIX/bin/sing-box"; ETC="$PREFIX/etc/sing-box"; CFG="$ETC/config.json"; LAUNCHER="$PREFIX/bin/singbox"; shift 2 ;;
    -h|--help)    cmd_help; exit 0 ;;
    --version)    if [ -z "$CMD" ]; then echo "singbox.sh v$VERSION"; exit 0; fi
                  [ -n "${2:-}" ] || die "--version 需要参数，如 --version 1.14.0"
                  ARGS+=("$1" "$2"); shift 2 ;;
    -*)           # 命令已确定时，后续参数交给子命令自行解析
                  if [ -n "$CMD" ]; then ARGS+=("$1"); shift
                  else die "未知参数：$1（-h 看帮助）"; fi ;;
    *)            if [ -z "$CMD" ]; then CMD="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done

# 平台检查放在参数解析之后：--help / --version 在任何系统上都应可用
check_platform

# 不收参数的命令：dispatch 里它们都写成 `cmd_xxx ;;`，不转发 $ARGS，
# 于是 `singbox.sh status thisIsBogus` 会一声不响地正常跑完并退 0。
# 与 cmd_install / cmd_config 的 `*) die "未知参数"` 约定不一致，这里统一补上门卫。
# 逐个函数加参数解析没有意义——它们本来就不收参数。
case "${CMD:-status}" in
  sysprep|status|verify|syscheck|start|restart|debug|rules|update|rollback|doctor|uninstall|help)
    [ "${#ARGS[@]}" -eq 0 ] || die "${CMD:-status} 不接受参数：${ARGS[*]}（-h 看帮助）" ;;
esac

case "${CMD:-status}" in
  install)   cmd_install ${ARGS[@]+"${ARGS[@]}"} ;;
  sysprep)   cmd_sysprep ;;
  status)    cmd_status ;;
  verify)    cmd_verify ;;
  syscheck)  cmd_syscheck ;;
  start)     cmd_start ;;
  stop)      cmd_stop ${ARGS[@]+"${ARGS[@]}"} ;;
  restart)   cmd_restart ;;
  enable)    cmd_enable ;;
  disable)   cmd_disable ${ARGS[@]+"${ARGS[@]}"} ;;
  logs)      cmd_logs ${ARGS[@]+"${ARGS[@]}"} ;;
  debug)     cmd_debug ;;
  edit)      cmd_edit ${ARGS[@]+"${ARGS[@]}"} ;;
  config)    cmd_config ${ARGS[@]+"${ARGS[@]}"} ;;
  rules)     cmd_rules ;;
  update)    cmd_update ;;
  rollback)  cmd_rollback ;;
  dns)       cmd_dns ${ARGS[@]+"${ARGS[@]}"} ;;
  mirror)    cmd_mirror ${ARGS[@]+"${ARGS[@]}"} ;;
  doctor)    cmd_doctor ;;
  uninstall) cmd_uninstall ;;
  help)      cmd_help ;;
  *)         bad "未知命令：$CMD"; echo; cmd_help; exit 1 ;;
esac
