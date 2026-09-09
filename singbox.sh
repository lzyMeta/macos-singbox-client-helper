#!/usr/bin/env bash
#
# singbox.sh —— sing-box on macOS 全生命周期管理
#
# 配套《在 macOS 上直接运行 sing-box —— 配置最佳实践》
#
# 用法：singbox <命令> [参数]
#   install    首次安装（内核 + 系统层准备 + 配置 + 服务）
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
#   update     升级内核（沙箱验证 → 升级 → 验收，任一步失败自动回滚）
#   rollback   换回上一个内核（$BIN.prev）并重新验收
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
set -uo pipefail

VERSION="1.1.0"

#=======================================================================
# 全局变量与默认值
#=======================================================================
PREFIX="${SB_PREFIX:-/usr/local}"
BIN="$PREFIX/bin/sing-box"
ETC="$PREFIX/etc/sing-box"
CFG="$ETC/config.json"
PLIST=/Library/LaunchDaemons/sing-box.plist
LABEL=system/sing-box
# 日志目录。默认 /var/log，与 plist 里写死的绝对路径一致。
# 做成可覆盖不只是为了测试：路径写死正是「日志涨到几百 MB 也没有任何测试能发现」
# 的直接原因。install 时的取值会被烧进 plist，所以改了它就得重装服务。
LOGDIR="${SB_LOGDIR:-/var/log}"
LOGFILE="$LOGDIR/sing-box.log"
ERRFILE="$LOGDIR/sing-box.err"
LOCKDIR=/tmp/.singbox-sh.lock
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
LOCK_HELD=0
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
latest_version() {
  local v m
  v=$(curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$NET_TIMEOUT" "$GH_API" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }

  for m in $(mirror_list); do
    printf '    查询版本 ← %s … ' "$m" >&2
    v=$(curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time 12 \
        "$(mirror_url "$m" "$GH_API")" 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$v" ]; then printf '%s\n' "$v" >&2; printf '%s' "$v"; return 0; fi
    printf '%s无结果%s\n' "$C_DIM" "$C_N" >&2
  done

  # 最后一招：releases/latest 会 302 到 .../tag/vX.Y.Z
  v=$(curl -fsIL --connect-timeout "$CONNECT_TIMEOUT" --max-time 15 "$GH_RELEASES" 2>/dev/null \
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
  api="$GH_API_REPO/releases/tags/v${ver#v}"
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
  step "0/7  环境检查"
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
  step "1/7  安装 sing-box 内核"
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

  #--- 2 系统层 ---
  step "2/7  macOS 系统层准备"
  info "这三项配置文件管不了；不做的话后面验证一定过不去，而症状不指向真正原因。"
  _sysprep

  #--- 3 配置 ---
  step "3/7  放置配置文件"
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

  #--- 4 校验 ---
  step "4/7  静态校验"
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
    if grep -qi deprecated "$chklog"; then
      warn "存在废弃字段告警（不阻止启动，但可能已静默降级）："
      grep -i deprecated "$chklog" | sed 's/^/        /' >&2
    fi
  fi

  #--- 5 前台试跑 ---
  step "5/7  前台试跑"
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

  #--- 6 服务 ---
  step "6/7  安装 LaunchDaemon"
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

  #--- 7 验证 ---
  step "7/7  验证"
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
  local routes; routes=$(netstat -rn -f inet 2>/dev/null | grep -E 'default|^0/1|^128\.0/1')
  printf '%s\n' "$routes" | sed 's/^/      /'
  if printf '%s' "$routes" | grep -q utun; then
    ok "路由已指向 utun"
    dim "指向 en0 的那条 default 必须保留 —— 内核出站流量要靠它"
  else
    bad "路由未指向 utun：TUN 未接管，跑 doctor"
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
  v6addr=$(ifconfig 2>/dev/null | grep inet6 | grep -v 'fe80::' | grep -v '::1 ')
  if [ -z "$v6addr" ]; then
    ok "无全局 IPv6 地址"
    dim "fe80::（链路本地）与 ::1（环回）属正常，关不掉也不该关"
  else
    bad "仍有全局 IPv6 地址："
    printf '%s\n' "$v6addr" | sed 's/^/        /' >&2
    bad_count=$((bad_count+1))
  fi

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

  step "1/5  节点链路（绕开 TUN）"
  local ip_socks
  ip_socks=$(curl -s --max-time 12 -x "socks5h://$s" https://api.ipify.org 2>/dev/null)
  if [ -n "$ip_socks" ]; then
    ok "SOCKS 出口：$ip_socks"
  else
    bad "SOCKS 不通 —— 问题在节点参数（uuid / SNI / public_key / short_id / flow / Mux）"
    info "与 TUN、路由规则无关；这一步不过，后面的结果都没有参考价值"
    return 1
  fi

  step "2/5  出口 IP 分流"
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

  step "3/5  DNS 防泄漏"
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

  step "4/5  IPv6 与 QUIC"
  local v6; v6=$(ifconfig 2>/dev/null | grep inet6 | grep -v 'fe80::' | grep -v '::1 ')
  [ -z "$v6" ] && ok "无全局 IPv6" || vbad "存在全局 IPv6 —— 跑 syscheck"
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

  step "5/5  国内直连与局域网"
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

  # 退出码要如实反映五步的结果，并且要能分辨「回滚有用」和「回滚白搭」：
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
  grep -qi deprecated "$chk" && warn "存在废弃字段告警（不阻止启动）"
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
    *) die "config: 未知子命令 $1（show|backup|list|diff|restore）" ;;
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
#   3 验收   cmd_verify 五步，失败重试一轮再判回滚
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
    if _sb_port_listening "$port"; then up=0; break; fi
    i=$((i + 1)); sleep 1
  done
  if [ "$up" != 0 ]; then
    bad "沙箱实例没能起来（端口 ${port} 始终没有监听）"
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

# 升级后要确认的三件确定性的事：进程活着、TUN 路由在、监听端口在听。
# 三样都不依赖外网，是「起来了没有」最硬的判据——阶段 3 那些依赖公网的检查
# 会抖，这一层不会。
_sb_health() {
  local n=0 port routes
  running && ok "进程存活" || { bad "进程未出现"; n=$((n + 1)); }
  # ⚠️ 两处都别想当然：
  # 1) 别写成 `netstat … | grep -q utun`。grep -q 一命中就退出，netstat 吃 SIGPIPE
  #    死掉，pipefail 把那个 141 当成整条管道的退出码——「路由在」被判成「路由没了」，
  #    撞不撞得上取决于调度时机，是偶发的。这里的 grep 不带 -q，会读到 EOF，没这问题。
  # 2) 别拿整张表宽匹配 utun。TUN 接口自身那条 UH 主机路由只证明接口建起来了，
  #    不证明流量被接管；接口在而 auto_route 没装上，流量就从 en0 裸奔——那正是
  #    这个功能要挡的故障。判据与 cmd_status 一致：先过滤出默认/分流默认路由再看。
  routes=$(netstat -rn -f inet 2>/dev/null | grep -E 'default|^0/1|^128\.0/1')
  case "$routes" in
    *utun*) ok "TUN 已接管默认路由" ;;
    *)      bad "默认路由没有指向 utun —— TUN 未接管"; n=$((n + 1)) ;;
  esac
  port=$(sock_addr); port="${port##*:}"
  if _sb_port_listening "$port"; then
    ok "监听端口 ${port} 在听"
  else
    bad "监听端口 ${port} 没有在听"; n=$((n + 1))
  fi
  [ "$n" = 0 ]
}

# 废弃字段照打照记，但一个字都不自动改——改写配置需要读 release notes 与
# 上游文档，验收标准和「安全升级」完全不是一回事。
_sb_warn_deprecated() {
  grep -qi deprecated "$1" || return 0
  warn "存在废弃字段告警（本脚本不会自动改写配置）："
  grep -i deprecated "$1" | sed 's/^/        /' >&2
}

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
  _sb_warn_deprecated "$chk"

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
    info "以上均未执行。"
    return 0
  fi

  sudo mv "$BIN.prev" "$BIN" || die "回滚失败：换不回 ${BIN}"
  sudo xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
  ok "已换回 ${prev:-旧版本}"
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
    echo; echo "===== 路由 ====="; netstat -rn -f inet 2>&1 | grep -E 'default|^0/1|^128\.0/1'
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
  grep -qi "deprecated" "$out" && { warn "存在废弃字段（不阻止启动，但可能静默降级）"; DOCTOR_FOUND=1; }
  netstat -rn -f inet 2>/dev/null | grep -E 'default|^0/1' | grep -q utun || _hit "路由未指向 utun：TUN 未接管"
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
  update              升级内核：预检 → 沙箱验证 → 升级 → 验收
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
    --prefix)     PREFIX="${2:-}"; [ -n "$PREFIX" ] || die "--prefix 需要参数"
                  BIN="$PREFIX/bin/sing-box"; ETC="$PREFIX/etc/sing-box"; CFG="$ETC/config.json"; shift 2 ;;
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
