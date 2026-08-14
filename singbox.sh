#!/usr/bin/env bash
#
# singbox.sh —— sing-box on macOS 全生命周期管理
#
# 配套《在 macOS 上直接运行 sing-box —— 配置最佳实践》
#
# 用法：singbox <命令> [参数]
#   install    首次安装（内核 + 系统层准备 + 配置 + 服务）
#   status     服务状态、TUN 路由、监听端口
#   verify     完整验证清单
#   syscheck   系统层复查（换网络 / 换硬件后跑）
#   start | stop | restart
#   enable | disable
#   logs [n|-f]
#   debug      debug 前台跑，看分流命中
#   edit       改配置（校验 + 备份 + 重启）
#   config     配置子命令：show / backup / restore / diff
#   rules      验证规则集 URL
#   update     升级内核（失败回滚）
#   doctor     一键诊断
#   uninstall  卸载
#
# 全局参数：
#   -y, --yes        非交互，所有询问取默认值
#   -q, --quiet      只输出警告与错误
#   -n, --dry-run    只打印将要执行的操作
#   --prefix <dir>   安装前缀（默认 /usr/local）
#   -h, --help       帮助
#
set -uo pipefail

VERSION="1.0.0"

#=======================================================================
# 全局变量与默认值
#=======================================================================
PREFIX="${SB_PREFIX:-/usr/local}"
BIN="$PREFIX/bin/sing-box"
ETC="$PREFIX/etc/sing-box"
CFG="$ETC/config.json"
PLIST=/Library/LaunchDaemons/sing-box.plist
LABEL=system/sing-box
LOGFILE=/var/log/sing-box.log
ERRFILE=/var/log/sing-box.err
LOCKDIR=/tmp/.singbox-sh.lock
PREFS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/singbox"
PREFS="$PREFS_DIR/prefs"
DNS_BACKUP="$PREFS_DIR/dns-backup"
PROXY_DNS=1.1.1.1
DEFAULT_EDITOR=vi
GH_API=https://api.github.com/repos/SagerNet/sing-box/releases/latest
GH_DL=https://github.com/SagerNet/sing-box/releases/download
GH_RELEASES=https://github.com/SagerNet/sing-box/releases/latest

# 前缀式镜像：把完整的 github 链接接在后面即可。
# 这类站点更替频繁，脚本一律先探测再用，探不通就换下一个。
# 可用 SB_MIRRORS 环境变量覆盖（空格分隔），或 mirror set 固定一个。
DEFAULT_MIRRORS="https://ghfast.top https://gh-proxy.com https://ghproxy.net https://mirror.ghproxy.com"
NET_TIMEOUT=25
CONNECT_TIMEOUT=4      # 建连超时：镜像死了要快速失败，不要干等
PROBE_TIMEOUT=6        # 探测单个镜像的总时限
STALL_SECS=20          # 下载速度低于阈值持续这么久就放弃，换下一个
STALL_BYTES=2048

ASSUME_YES=0
QUIET=0
DRY=0
TMPFILES=()
SUDO_KEEPALIVE_PID=""
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

#=======================================================================
# 基础设施：清理、锁、sudo、交互
#=======================================================================
cleanup() {
  local rc=$?
  [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
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

# 防并发：两个实例同时改配置或加载服务会出错
acquire_lock() {
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
check_platform() {
  [ "$(uname -s)" = Darwin ] || die "本脚本仅适用于 macOS"
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

detect_arch() {
  case "$(uname -m)" in
    arm64)  echo arm64 ;;
    x86_64) echo amd64 ;;
    *)      echo "" ;;
  esac
}

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

# 带镜像回退的下载：download <目标文件> <github原始URL> [描述]
# 直连优先；失败则逐个试镜像；成功的镜像会被记住供后续使用
download() {
  local out="$1" url="$2" desc="${3:-文件}"

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

    printf '    [%d/%d] 探测 %s … ' "$i" "${#sources[@]}" "$label"
    if ! probe_url "$src" "$PROBE_TIMEOUT"; then
      printf '%s不通%s\n' "$C_DIM" "$C_N"
      continue
    fi
    printf '%s可用%s\n' "$C_OK" "$C_N"

    info "下载${desc} ← ${label}"
    t0=$(date +%s)
    if curl "${opts[@]}" -o "$out" "$src" && [ -s "$out" ]; then
      t1=$(date +%s)
      sz=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
      ok "下载完成：$(human_size "${sz:-0}")，耗时 $((t1-t0))s"
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

backup_config() {
  local bak="$CFG.$(date +%Y%m%d-%H%M%S).bak"
  run "sudo cp '$CFG' '$bak'" && info "已备份：$bak"
  printf '%s' "$bak"
}

# 只保留最近 N 份备份，避免无限堆积
prune_backups() {
  local keep="${1:-10}"
  local n; n=$(ls -1t "$CFG".*.bak 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -le "$keep" ] && return 0
  ls -1t "$CFG".*.bak 2>/dev/null | tail -n +$((keep+1)) | while read -r f; do
    sudo rm -f "$f"
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
      --config)  src_cfg="${2:-}"; shift 2 ;;
      --version) want_ver="${2:-}"; shift 2 ;;
      --arch)    arch="${2:-}"; shift 2 ;;
      --force)   force=1; shift ;;
      *) die "install: 未知参数 $1" ;;
    esac
  done

  check_deps
  acquire_lock
  need_root

  #--- 0 环境 ---
  step "0/7  环境检查"
  local host_arch; host_arch=$(detect_arch)
  [ -n "$host_arch" ] || die "不支持的 CPU 架构：$(uname -m)"
  [ -n "$arch" ] || arch="$host_arch"
  [ "$arch" = "$host_arch" ] || warn "指定架构 $arch 与本机 $host_arch 不符"
  info "架构：$(uname -m) → darwin-$arch"
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
      download "$tmpd/$tarball" "$url" "内核 v$want_ver" \
        || die "下载失败（版本号是否正确？）"
      tar xzf "$tmpd/$tarball" -C "$tmpd" || die "解压失败，文件可能不完整"
      local extracted="$tmpd/sing-box-${want_ver}-darwin-${arch}/sing-box"
      [ -f "$extracted" ] || die "压缩包结构异常，未找到 sing-box 可执行文件"
      sudo mkdir -p "$PREFIX/bin"
      # 已有旧版则先备份，便于失败回滚
      [ -x "$BIN" ] && sudo cp "$BIN" "$BIN.prev"
      sudo install -m 755 "$extracted" "$BIN" || die "安装失败，检查 $PREFIX/bin 写权限"
      sudo xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
      "$BIN" version >/dev/null 2>&1 || {
        [ -f "$BIN.prev" ] && sudo mv "$BIN.prev" "$BIN"
        die "新安装的二进制无法执行，已回滚"
      }
      sudo rm -f "$BIN.prev"
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
    backup_config >/dev/null
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
  [ "$DRY" = 0 ] && cmd_verify || true

  echo
  printf '%s安装完成。%s\n' "$C_B" "$C_N"
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
    dns_backup_save
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
  local nf; nf=$(grep -ci "failed to download rule.set\|rule.set.*fail" "$f" 2>/dev/null || echo 0)
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
  step "服务状态"
  info "内核：$("$BIN" version 2>/dev/null | head -1)"
  if running; then ok "sing-box 运行中（PID $(pgrep -x sing-box | tr '\n' ' '))"
  else bad "sing-box 未运行"; fi
  if daemon_loaded; then ok "LaunchDaemon 已加载"
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
  if [ -n "$pid" ]; then
    sudo lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null \
      | awk 'NR>1{printf "      %-26s %s\n",$9,$1}' || true
    sudo lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null | grep -q '\*:' \
      && warn "存在 *: 监听 —— 局域网可访问，应把 listen 改回 127.0.0.1"
  else
    dim "（进程未运行）"
  fi
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
  fi
}

#=======================================================================
# verify
#=======================================================================
cmd_verify() {
  require_installed
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
  local ip_main ip_soc org
  ip_main=$(curl -s --max-time 12 https://api.ipify.org 2>/dev/null)
  local soc_json; soc_json=$(curl -s --max-time 15 https://ipinfo.io/json 2>/dev/null)
  ip_soc=$(printf '%s' "$soc_json" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("ip",""))
except Exception: print("")' 2>/dev/null)
  org=$(printf '%s' "$soc_json" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("org",""))
except Exception: print("")' 2>/dev/null)
  info "兜底出站   ：${ip_main:-取不到}        （应为 vpstrans 机房 IP）"
  info "社交组出站 ：${ip_soc:-取不到}  ${org}  （应为 vpsre 住宅 IP）"
  if [ -z "$ip_main" ]; then
    bad "兜底取不到 IP —— 跑 status 看 TUN 是否接管"
  elif [ -z "$ip_soc" ]; then
    warn "ipinfo.io 取不到，跳过分流判断"
  elif [ "$ip_main" = "$ip_soc" ]; then
    bad "两个出口相同 —— 服务端按 UUID 分流未生效，或 vpsre 中转链路断了"
    info "这是服务端问题，客户端配置改不了"
    dim "也可能是 ipinfo.io 没命中社交规则集；用 debug 确认它走的是哪个出站"
  else
    ok "两个出口不同，UUID 分流生效"
    dim "确认上面的 org 是住宅运营商而非机房"
  fi

  step "3/5  DNS 防泄漏"
  if command -v dig >/dev/null 2>&1; then
    local g; g=$(dig +short +time=3 +tries=1 www.google.com 2>/dev/null | grep -E '^[0-9]' | head -3 | tr '\n' ' ')
    info "google.com → ${g:-无结果}"
    case "$g" in
      157.240.*|31.13.*|"") bad "解析结果异常（疑似污染）—— 跑 syscheck 看系统 DNS 是不是内网地址" ;;
      *) ok "解析正常" ;;
    esac
  else
    dim "未装 dig，跳过（brew install bind）"
  fi
  dim "浏览器验证：dnsleaktest.com 的 Extended Test 不应出现本地运营商"

  step "4/5  IPv6 与 QUIC"
  local v6; v6=$(ifconfig 2>/dev/null | grep inet6 | grep -v 'fe80::' | grep -v '::1 ')
  [ -z "$v6" ] && ok "无全局 IPv6" || bad "存在全局 IPv6 —— 跑 syscheck"
  if curl --http3 -V >/dev/null 2>&1 || curl -V 2>/dev/null | grep -q HTTP3; then
    local hv; hv=$(curl -s --max-time 8 -o /dev/null -w '%{http_version}' --http3 https://cloudflare-quic.com/ 2>/dev/null)
    [ "$hv" = "3" ] && warn "HTTP/3 仍可用 —— 检查禁 QUIC 规则（udp + 443 + reject）" || ok "QUIC 已阻断"
  else
    dim "本机 curl 不支持 http3，跳过；可用浏览器访问 cloudflare-quic.com 验证"
  fi

  step "5/5  国内直连与局域网"
  local cn; cn=$(curl -s --max-time 12 https://cip.cc 2>/dev/null | head -4 | tr '\n' ' ')
  info "cip.cc → ${cn:-取不到}"
  local gw; gw=$(netstat -rn -f inet 2>/dev/null | awk '/^default/ && $6!~/utun/ {print $2; exit}')
  if [ -n "$gw" ]; then
    ping -c1 -W1500 "$gw" >/dev/null 2>&1 && ok "局域网网关 $gw 可达" \
      || warn "网关不可达 —— 检查私有网段规则是否排在最前"
  fi
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
}

#=======================================================================
# debug
#=======================================================================
cmd_debug() {
  require_installed
  need_root
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
  _stop_all_instances

  trap '_debug_restore; cleanup' EXIT INT TERM
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
  if ! $ed "$tmp"; then
    local rc=$?
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
    local keep="/tmp/sb-edit-failed-$(date +%H%M%S).json"
    cp "$tmp" "$keep"; info "你的修改已保留：$keep"
    return 1
  fi
  local chk; chk=$(mktmp)
  if ! sudo "$BIN" check -c "$tmp" >"$chk" 2>&1; then
    bad "check 未通过，未应用"
    sed 's/^/      /' "$chk" >&2
    local keep="/tmp/sb-edit-failed-$(date +%H%M%S).json"
    cp "$tmp" "$keep"; info "你的修改已保留：$keep"
    return 1
  fi
  grep -qi deprecated "$chk" && warn "存在废弃字段告警（不阻止启动）"
  ok "校验通过"

  backup_config >/dev/null
  prune_backups 10
  sudo cp "$tmp" "$CFG"
  sudo chown root:wheel "$CFG"; sudo chmod 644 "$CFG"
  cmd_restart
}

cmd_config() {
  require_installed
  case "${1:-show}" in
    show)   sudo cat "$CFG" ;;
    backup) need_root; backup_config >/dev/null; prune_backups 10; ok "已备份" ;;
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
      backup_config >/dev/null
      sudo cp "$b" "$CFG"; sudo chown root:wheel "$CFG"; sudo chmod 644 "$CFG"
      ok "已恢复"; cmd_restart ;;
    *) die "config: 未知子命令 $1（show|backup|list|diff|restore）" ;;
  esac
}

#=======================================================================
# 服务控制
#=======================================================================
cmd_start() {
  require_installed; need_root
  [ -f "$PLIST" ] || die "未安装服务 —— 先运行 install"
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
  dns_is_proxy_mode || return 0
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
  require_installed; need_root
  if daemon_loaded; then
    if sudo launchctl kickstart -k "$LABEL" 2>/dev/null; then
      sleep 3
      running && ok "已重启" || { bad "重启后未运行"; sudo tail -20 "$ERRFILE" 2>/dev/null | sed 's/^/      /'; return 1; }
    else
      warn "kickstart 失败，改为重新加载"
      cmd_stop; cmd_start
    fi
  else
    info "服务未加载，直接启动"
    cmd_start
  fi
}

cmd_enable()  { need_root; sudo launchctl enable "$LABEL" 2>/dev/null && ok "已启用（跨重启生效）" || warn "操作失败"; }
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
  sudo launchctl bootout "$LABEL" 2>/dev/null || true
  sudo launchctl disable "$LABEL" 2>/dev/null && ok "已停用（重启后也不会自启）" || warn "操作失败"
  sleep 1
  running && warn "仍有进程在跑（前台实例不受 launchd 管辖，需自行 Ctrl-C）"
  dim "恢复：$(basename "$0") enable && $(basename "$0") start"
  _maybe_restore_dns "$restore_dns" "$dns_target"
}

cmd_logs() {
  local a="${1:-50}"
  [ -f "$LOGFILE" ] || die "日志文件不存在：${LOGFILE}（服务可能从未启动过）"
  if [ "$a" = "-f" ]; then sudo tail -f "$LOGFILE"
  elif [[ "$a" =~ ^[0-9]+$ ]]; then sudo tail -"$a" "$LOGFILE"
  else die "logs: 参数应为行数或 -f"; fi
}

#=======================================================================
# update
#=======================================================================
cmd_update() {
  require_installed; need_root; acquire_lock
  step "升级内核"
  local cur new arch
  cur=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
  info "当前：${cur:-未知}"
  new=$(latest_version) || die "无法获取最新版本（GitHub 与所有镜像均不可达）；可用 install --version 手动指定"
  info "最新：$new"
  [ "$cur" = "$new" ] && { ok "已是最新"; return 0; }
  ask "升级到 ${new}？" n || return 0

  arch=$(detect_arch)
  local tmpd; tmpd=$(mktmpd)
  download "$tmpd/sb.tar.gz" "$GH_DL/v${new}/sing-box-${new}-darwin-${arch}.tar.gz" "内核 v$new" \
    || die "下载失败"
  tar xzf "$tmpd/sb.tar.gz" -C "$tmpd" || die "解压失败"
  local newbin="$tmpd/sing-box-${new}-darwin-${arch}/sing-box"
  [ -f "$newbin" ] || die "压缩包结构异常"

  sudo cp "$BIN" "$BIN.prev" || die "备份旧版失败"
  sudo install -m 755 "$newbin" "$BIN" || { sudo mv "$BIN.prev" "$BIN"; die "安装失败，已回滚"; }
  sudo xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true

  local chk; chk=$(mktmp)
  if "$BIN" version >/dev/null 2>&1 && sudo "$BIN" check -c "$CFG" >"$chk" 2>&1; then
    ok "新版本校验配置通过"
    grep -qi deprecated "$chk" && {
      warn "存在废弃字段告警："
      grep -i deprecated "$chk" | sed 's/^/        /' >&2
    }
    sudo rm -f "$BIN.prev"
    cmd_restart
    warn "srs 规则集有格式版本，接着跑：$(basename "$0") rules"
  else
    bad "新版本下配置校验失败，回滚"
    sed 's/^/      /' "$chk" >&2
    sudo mv "$BIN.prev" "$BIN"
    cmd_restart
    return 1
  fi
}

#=======================================================================
# dns
#=======================================================================
cmd_dns() {
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
      step "设为 $addr"; dns_restore "$addr" ;;
    *) die "dns: 未知子命令 $1（status|dhcp|backup|proxy|set <地址>）" ;;
  esac
}

#=======================================================================
# mirror
#=======================================================================
cmd_mirror() {
  case "${1:-test}" in
    test)
      step "探测镜像可用性"
      dim "这类站点更替频繁，结果只代表此刻；每个最多等 ${PROBE_TIMEOUT}s"
      local probe_path="$GH_DL/v1.12.0/sing-box-1.12.0-darwin-amd64.tar.gz"
      local m t0 t1
      _probe_one() {
        local label="$1" u="$2" a b
        a=$(date +%s)
        if probe_url "$u" "$PROBE_TIMEOUT"; then b=$(date +%s)
          printf '      %-34s %s可用%s  %ss\n' "$label" "$C_OK" "$C_N" "$((b-a))"
        else b=$(date +%s)
          printf '      %-34s %s不通%s  %ss\n' "$label" "$C_ERR" "$C_N" "$((b-a))"
        fi
      }
      _probe_one "直连 github.com" "$probe_path"
      for m in $(mirror_list); do _probe_one "$m" "$(mirror_url "$m" "$probe_path")"; done
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
      if probe_url "$(mirror_url "$m" "$GH_DL/v1.12.0/sing-box-1.12.0-darwin-amd64.tar.gz")" "$PROBE_TIMEOUT"; then
        prefs_set mirror "$m" && ok "已固定为首选镜像"
      else
        warn "该镜像此刻探测不通"
        ask "仍然保存？" n && { prefs_set mirror "$m" && ok "已保存"; } || info "未保存"
      fi
      ;;
    reset) prefs_unset mirror; ok "已清除镜像偏好，恢复为直连优先 + 内置列表" ;;
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
  local out="/tmp/singbox-doctor-$(date +%Y%m%d-%H%M%S).txt"
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
  [ "$DOCTOR_FOUND" = 0 ] && ok "未发现已知问题模式"
  echo
  info "把 $out 的内容贴出来即可定位大多数问题"
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
  sudo rm -f "$PLIST"
  ok "服务已移除"
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
    for x in ${found[@]+"${found[@]}"}; do rm -rf "$x" && info "  已删除 $x"; done
    ok "残留已清理"
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
  logs [n|-f]         看日志

检查
  verify              完整验证清单（节点/出口 IP/DNS/IPv6/QUIC/国内直连）
  syscheck            系统层复查（换网络、换硬件后跑）
  rules               验证规则集 URL 可达
  debug               debug 前台跑，看每条连接落在哪个出站
  doctor              收集诊断并自动判读

维护
  update              升级内核（校验失败自动回滚）
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
                  ARGS+=("$1" "${2:-}"); shift 2 ;;
    -*)           # 命令已确定时，后续参数交给子命令自行解析
                  if [ -n "$CMD" ]; then ARGS+=("$1"); shift
                  else die "未知参数：$1（-h 看帮助）"; fi ;;
    *)            if [ -z "$CMD" ]; then CMD="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done

# 平台检查放在参数解析之后：--help / --version 在任何系统上都应可用
check_platform

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
  dns)       cmd_dns ${ARGS[@]+"${ARGS[@]}"} ;;
  mirror)    cmd_mirror ${ARGS[@]+"${ARGS[@]}"} ;;
  doctor)    cmd_doctor ;;
  uninstall) cmd_uninstall ;;
  help)      cmd_help ;;
  *)         bad "未知命令：$CMD"; echo; cmd_help; exit 1 ;;
esac
