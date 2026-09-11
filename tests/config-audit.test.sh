#!/usr/bin/env bash
#
# tests/config-audit.test.sh —— `config audit` 发现层的断言。
#
# 这份测试盯的是一件事：**两路合流必须真的互补，不能有一路是摆设。**
#
#   check 档   抓「废弃但仍接受」（WARN，自带官方 migration 链接）与「已移除」（FATAL）
#   schema 档  抓「schema 里不存在的键」——sing-box 的 schema 生成器剔除了全部废弃字段
#
# 本功能的成因正是 check 档对 download_detour **一个字都不打**（实测 1.14.0：
# check 退 0、无输出），而脚本原先四处 `grep -qi deprecated` 全都只看 check 输出。
# 所以断言 1 不只验退出码，还要验那条发现是**从 schema 档**来的——桩要是让 check
# 对 download_detour 出声，这条就会从 check 档走掉，互补性就测没了。
#
# 全程离线、不要 sudo、不碰真实系统：--config 指向 fixture（这正是那个参数存在的
# 理由），--prefix 指到临时目录，假内核由 mk_bin 装到 $ROOT/prefix/bin。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SB="${SB_UNDER_TEST:-./singbox.sh}"
FIXBIN="$PWD/tests/fixtures/bin"
FAKE="$PWD/tests/fixtures/fake-sing-box"
FIX="$PWD/tests/fixtures"
VER=1.14.0

pass=0; fail=0
ROOT=""; LOG=""; CODE=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ng() {
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/          | /'
  [ -n "$LOG" ] && [ -s "$LOG" ] && tail -30 "$LOG" | sed 's/^/          > /'
  fail=$((fail + 1))
}

# 把假内核装到某个路径上，版本号烧进去（同 tests/update.test.sh）
mk_bin() { sed "s/__VERSION__/$2/" "$FAKE" > "$1"; chmod 755 "$1"; }

setup() {
  teardown
  ROOT=$(mktemp -d)
  LOG="$ROOT/out.log"
  mkdir -p "$ROOT/prefix/bin" "$ROOT/prefix/etc/sing-box"
  mk_bin "$ROOT/prefix/bin/sing-box" "${1:-$VER}"
  # require_installed 要求 $CFG 存在。审查目标由 --config 指定，这份只是过闸门用，
  # 内容必须干净——它要是带废弃项，「--config 真的生效了吗」就没人验得出来。
  cp "$FIX/good-http-client.json" "$ROOT/prefix/etc/sing-box/config.json"
  export XDG_CONFIG_HOME="$ROOT/xdg"; mkdir -p "$XDG_CONFIG_HOME"
  # tests/fixtures/bin/curl 开头是 ${SB_FAKE_STATE:?}，不设它那支桩一进来就退出，
  # 于是第 3 道会报「代理不通」——一个跟沙箱毫无关系的假红
  export SB_FAKE_STATE="$ROOT/state"; mkdir -p "$SB_FAKE_STATE"
  # 给桩指路：模板被 sed 到临时目录后读不到仓库的相对路径
  export SB_FAKE_SCHEMA="$FIX/schema-min.json"
}

teardown() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  rm -rf "${SB_LOCKDIR:-/tmp/.singbox-sh.lock}" 2>/dev/null
  ROOT=""
}
trap teardown EXIT

# use_cfg —— 把某份 fixture 装成 $CFG（--apply 只作用于 $CFG，测试靠 --prefix
# 把它指到临时目录，所以全程不碰 live 配置）
use_cfg() { cp "$FIX/$1.json" "$ROOT/prefix/etc/sing-box/config.json"; }
livecfg() { printf '%s' "$ROOT/prefix/etc/sing-box/config.json"; }

# audit —— 跑一次 config audit，退出码进 $CODE
audit() {
  PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y config audit "$@" >"$LOG" 2>&1
  CODE=$?
}
inlog() { grep -q "$1" "$LOG"; }

# ran —— 发现层真的跑到了吗。
# 没有这个锚，下面每一条「没有误报 X」都是恒绿（命令没跑，输出里当然没有 X），
# 而「已移除字段退 1」会撞上 die 自己的退出码 1。表头是发现层无条件打的。
ran() {
  if inlog '配置审查：'; then
    ok "$1：发现层跑起来了"
  else
    ng "$1：发现层没跑起来（下面的断言全部不可信）"
  fi
}

echo "验证 config audit 的发现层"

#-- 1. download_detour：check 沉默，必须由 schema 档抓到，退 2 --------------
setup
audit --config "$FIX/bad-download-detour.json"
ran "带 download_detour"
if [ "$CODE" = 2 ]; then
  ok "带 download_detour：退出 2"
else
  ng "带 download_detour：期望 2，实际 $CODE"
fi

if inlog 'route\.rule_set\[0\]\.download_detour'; then
  ok "报告点名了具体键路径 route.rule_set[0].download_detour"
else
  ng "报告没点名键路径（spec 明令不许只说「不匹配任何分支」）"
fi

if inlog 'route\.rule_set\[1\]\.download_detour'; then
  ok "两条 remote 都被点名（漏报一条 = --apply 漏改一条）"
else
  ng "只报了一条，第二条 remote 漏了"
fi

# 这条是整份测试的重心：check 对 download_detour 沉默，所以它只可能从 schema 档来。
if inlog 'schema'; then
  ok "发现来自 schema 档（check 档对它沉默）"
else
  ng "发现没有标注来源 schema —— 两路合流的互补性没有被验证"
fi

#-- 1b. 合法的同名子串字段不许误报 -----------------------------------------
# experimental.clash_api.external_ui_download_detour 是 1.14.0 **仍然有效**的字段，
# 名字里含 download_detour。凡是拿子串计数找废弃项的写法都会在这里假阳性——
# 实测真内核 schema 里 "download_detour" 的子串命中数是 1，正是它。
if inlog 'external_ui_download_detour'; then
  ng "误报了 external_ui_download_detour（合法字段，撞了子串）"
else
  ok "没有误报 external_ui_download_detour（说明不是子串计数）"
fi

# rule_set[2] 是 type: local，本来就没有 download_detour，不该出现在报告里
if inlog 'route\.rule_set\[2\]'; then
  ng "误报了 rule_set[2]（type: local，无废弃项）"
else
  ok "没有误报 type: local 的那一条"
fi

#-- 2. 已经是内联 http_client：干净，退 0 ----------------------------------
setup
audit --config "$FIX/good-http-client.json"
ran "已迁移"
if [ "$CODE" = 0 ]; then
  ok "已迁移到 http_client：退出 0"
else
  ng "已迁移到 http_client：期望 0，实际 $CODE"
fi

if inlog 'download_detour'; then
  ng "干净配置里仍报出 download_detour"
else
  ok "干净配置无任何发现"
fi

#-- 3. 已移除字段：check FATAL，退 1 ---------------------------------------
setup
audit --config "$FIX/bad-removed-field.json"
ran "带已移除字段"
if [ "$CODE" = 1 ]; then
  ok "带已移除字段：退出 1"
else
  ng "带已移除字段：期望 1，实际 $CODE"
fi

if inlog 'inet4_address'; then
  ok "报告点名了已移除的 inet4_address"
else
  ng "报告没点名 inet4_address"
fi

# 已移除是 check 档的独占能力：schema fixture 对 inbounds 不做约束，抓不到它
if inlog 'check'; then
  ok "发现来自 check 档（schema 档抓不到 inbound 内部）"
else
  ng "发现没有标注来源 check"
fi

#-- 9. --deep 是保留位，必须明说尚未实现且非 0 -----------------------------
setup
audit --config "$FIX/good-http-client.json" --deep
if [ "$CODE" != 0 ]; then
  ok "--deep：退出码非 0（实际 ${CODE}）"
else
  ng "--deep：期望非 0，实际 0 —— 保留位不能静默放行"
fi

if inlog '尚未实现'; then
  ok "--deep：明说尚未实现"
else
  ng "--deep：没说尚未实现"
fi

#-- 4/5. --apply：白名单改写 + 重跑发现层归零 ------------------------------
# 第 3 道（沙箱）默认走降级：SB_FAKE_UDP=dead 让它明确跳过，这样 4/5 两条断言
# 验的是改写本身，不用等 SANDBOX_WAIT。第 3 道的完整路径由后面单独一条覆盖。
setup
use_cfg bad-download-detour
cp "$(livecfg)" "$ROOT/before.json"
export SB_FAKE_UDP=dead
echo 1 > "$SB_FAKE_STATE/running"      # 让 cmd_restart 走到「已重启」那一支
audit --apply
if [ "$CODE" = 0 ]; then
  ok "--apply：四道验收后落地，退出 0"
else
  ng "--apply：期望 0，实际 ${CODE}"
fi

# 断言 4 —— 结构 diff 只落在白名单上，且值逐字相等。
# 这条**不复用实现里的白名单校验器**：那等于拿被测对象给自己打分。这里独立比对。
DIFFOUT=$(python3 - "$ROOT/before.json" "$(livecfg)" <<'PY'
import json, sys
def flat(o, p="", out=None):
    if out is None: out = {}
    if isinstance(o, dict):
        for k, v in o.items(): flat(v, (p + "." + k) if p else k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o): flat(v, "%s[%d]" % (p, i), out)
    else:
        out[p] = o
    return out
a, b = flat(json.load(open(sys.argv[1]))), flat(json.load(open(sys.argv[2])))
MISS = object()
bad = []
for k in set(a) | set(b):
    if a.get(k, MISS) == b.get(k, MISS): continue
    leaf = k.rsplit(".", 1)[-1]
    if k not in b and leaf == "download_detour":
        want = k.rsplit(".", 1)[0] + ".http_client.detour"
        if b.get(want) != a[k]:
            bad.append("值没有逐字搬移：%s=%r -> %s=%r" % (k, a[k], want, b.get(want)))
        continue
    if k not in a and k.endswith(".http_client.detour"):
        continue
    bad.append("白名单外的改动：%s  %r -> %r" % (k, a.get(k), b.get(k)))
print(chr(10).join(bad))
PY
)
if [ -z "$DIFFOUT" ]; then
  ok "--apply：结构 diff 只落在 download_detour → http_client.detour 上，值逐字相等"
else
  ng "--apply：改写越界" "$DIFFOUT"
fi

# 同级字段一字不变——③ 型错（重排时误删 update_interval）的直接靶子
if python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["route"]["rule_set"]
sys.exit(0 if d[0].get("update_interval")=="7d" and d[1].get("update_interval")=="3d" else 1)' "$(livecfg)"; then
  ok "--apply：同级 update_interval 一字未动"
else
  ng "--apply：update_interval 被改坏了"
fi

# 落地之后必须重启：文件改了不等于生效了，内核还在跑旧配置，err 日志里的
# deprecated 告警照样在涨。cmd_config restore 也是这么收尾的。
if inlog '重启'; then
  ok "--apply：落地后重启了服务"
else
  ng "--apply：只改了文件没重启 —— 改动没生效"
fi

# 断言 5 —— 改写后重跑发现层，归零
audit
if [ "$CODE" = 0 ] && ! inlog 'download_detour'; then
  ok "--apply 后重跑发现层：归零，退出 0"
else
  ng "--apply 后重跑发现层：期望 0 且无 download_detour，实际 ${CODE}"
fi

#-- -n（dry-run）：四道照跑，但一个字节都不写 ------------------------------
setup
use_cfg bad-download-detour
export SB_FAKE_UDP=dead
BEFORE_SUM=$(shasum "$(livecfg)" | awk '{print $1}')
PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y -n config audit --apply >"$LOG" 2>&1
CODE=$?
if [ "$CODE" = 0 ] && inlog '验收 4/4'; then
  ok "-n：四道验收照样跑完"
else
  ng "-n：期望 0 且跑完四道，实际 ${CODE}"
fi
if [ "$(shasum "$(livecfg)" | awk '{print $1}')" = "$BEFORE_SUM" ]; then
  ok "-n：配置一个字节都没被写"
else
  ng "-n：配置被改动了 —— dry-run 不该写盘"
fi
if inlog 'dry-run'; then
  ok "-n：明说了是干跑"
else
  ng "-n：没说这是干跑"
fi

#-- 6. 跨段污染必须被白名单 diff 拒绝 --------------------------------------
setup
use_cfg bad-download-detour
export SB_FAKE_UDP=dead
export SB_FAKE_MIGRATED="$FIX/bad-migrated-crosscontam.json"
audit --apply
if [ "$CODE" != 0 ]; then
  ok "⑤ 跨段污染（rules[1].outbound 被改）：拒绝落地，退出 ${CODE}"
else
  ng "⑤ 跨段污染：竟然落地了"
fi
if inlog 'route\.rules\[1\]\.outbound'; then
  ok "⑤ 拒绝时点名了越界的键路径"
else
  ng "⑤ 拒绝了但没说是哪个键越界"
fi
# 拒绝之后 $CFG 必须一字未动
if python3 -c 'import json,sys
rs=json.load(open(sys.argv[1]))["route"]["rule_set"]
sys.exit(0 if sum(1 for r in rs if "download_detour" in r)==2 else 1)' "$(livecfg)"; then
  ok "⑤ 拒绝后 live 配置保持原样（没有半途写进去）"
else
  ng "⑤ 拒绝了，但 live 配置已经被改动"
fi
unset SB_FAKE_MIGRATED

#-- 7. 值搬错（http_client 空对象）必须被拒绝 ------------------------------
setup
use_cfg bad-download-detour
export SB_FAKE_UDP=dead
export SB_FAKE_MIGRATED="$FIX/bad-migrated-emptyclient.json"
audit --apply
if [ "$CODE" != 0 ]; then
  ok "② 值搬错（http_client 为空对象）：拒绝落地，退出 ${CODE}"
else
  ng "② 值搬错：竟然落地了"
fi
if inlog 'detour 丢了'; then
  ok "② 拒绝时说明了 detour 没搬过来"
else
  ng "② 拒绝了但没说明原因"
fi
unset SB_FAKE_MIGRATED

#-- ①. 漏改必须被第 4 道抓住 -----------------------------------------------
# 这一型前三道全漏，是第 4 道唯一独占的职责：漏改**不产生 diff**（那一条两边
# 一模一样），check 对 download_detour 沉默，沙箱照样起得来。没有这条断言，
# 第 4 道就是死代码。
setup
use_cfg bad-download-detour
export SB_FAKE_UDP=dead
export SB_FAKE_MIGRATED="$FIX/bad-migrated-partial.json"
audit --apply
if [ "$CODE" != 0 ]; then
  ok "① 漏改（2 条只改了 1 条）：拒绝落地，退出 ${CODE}"
else
  ng "① 漏改：竟然落地了 —— 第 4 道没拦住"
fi
if inlog '验收 1/4'  && inlog '✓'; then
  ok "① 漏改确实通过了第 1 道白名单 diff（所以拦它的只可能是第 4 道）"
else
  ng "① 漏改在第 1 道就被拦了 —— 那第 4 道仍然没被验证过"
fi
if inlog '仍有 1 处'; then
  ok "① 拒绝时报出了还剩几处没改"
else
  ng "① 拒绝了但没说还剩几处"
fi
unset SB_FAKE_MIGRATED

#-- 8. 内核 < 1.14.0：--apply 直接失败 -------------------------------------
# http_client 那时候还不存在，改写过去等于把配置写成新内核才认识的样子
setup 1.13.14
use_cfg bad-download-detour
export SB_FAKE_UDP=dead
audit --apply
if [ "$CODE" != 0 ]; then
  ok "内核 1.13.14：--apply 失败，退出 ${CODE}"
else
  ng "内核 1.13.14：--apply 竟然成功了"
fi
if inlog '1\.14\.0'; then
  ok "内核 1.13.14：说明了 http_client 需要 ≥ 1.14.0"
else
  ng "内核 1.13.14：没说清为什么不许改"
fi

#-- 3 道 vs 4 道：沙箱那一道必须真的会跑，也必须会降级 ----------------------
# 只测降级路径的话，第 3 道就是死代码——它永远不被执行，坏了也没人知道。
setup
use_cfg bad-download-detour
export SB_FAKE_UDP=dead
audit --apply
if inlog '只过了 3/4 道'; then
  ok "网络不通：明确告知只过了 3/4 道"
else
  ng "网络不通：降级了却没说，用户以为四道全过"
fi

setup
use_cfg bad-download-detour
export SB_FAKE_UDP=alive
audit --apply
if [ "$CODE" = 0 ]; then
  ok "网络可用：四道全过后落地"
else
  ng "网络可用：期望 0，实际 ${CODE}"
fi
# ⚠️ 不能断言 inlog '沙箱'：step "验收 3/4　沙箱起得来" 是无条件打印的，降级分支的
# warn 里也写着「沙箱」二字 —— 那条断言在两条路径下都成立，把整段沙箱代码删掉换成
# passed=3 它照样绿。要区分，只能钉住**只有真跑才会出现**的东西。
if inlog '沙箱建链成功' && ! inlog '只过了 3/4 道'; then
  ok "网络可用：第 3 道真的跑了（建链成功，且没有走降级）"
else
  ng "第 3 道没被执行 —— 它是死代码（或者走了降级路径）"
fi
unset SB_FAKE_UDP

#-- 挂载点：cmd_verify 第 6 步（配置现代性，策略档）------------------------
# tests/verify.test.sh 里 $BIN 是个空文件，发现层的前置闸门会直接返回 —— 也就是
# 那 16 条断言全程没碰过第 6 步。不在这里补一条，这个挂载点就是死代码。
# 断言看的是**输出**不是退出码：verify 别的步骤也可能 vpbad 退 2，只有点名
# 「6/6」和废弃项条数才证明是第 6 步在说话。
verify_run() {
  export SB_FAKE_LIVE_PORT=21808     # 与 fixture 里 mixed 的 listen_port 对齐
  export SB_FAKE_QUIC=blocked        # 不钉死会真往公网发 UDP
  export SB_FAKE_UDP=alive
  echo 1 > "$SB_FAKE_STATE/running"
  echo 0 > "$SB_FAKE_STATE/verify_calls"
  echo 0 > "$SB_FAKE_STATE/ping_calls"
  echo 0 > "$SB_FAKE_STATE/ipinfo_calls"
  PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -y verify >"$LOG" 2>&1
  CODE=$?
}

setup
use_cfg bad-download-detour
verify_run
if inlog '6/6'; then
  ok "verify：第 6 步（配置现代性）真的跑了"
else
  ng "verify：没有第 6 步 —— 挂载点没生效"
fi
if inlog '配置里有 2 处废弃'; then
  ok "verify：脏配置被第 6 步点名（2 处）"
else
  ng "verify：脏配置没被第 6 步点名"
fi
if [ "$CODE" = 2 ]; then
  ok "verify：脏配置走策略档，退出 2（不该触发回滚）"
else
  ng "verify：期望 2（策略档），实际 ${CODE}"
fi

setup
use_cfg good-http-client
verify_run
if inlog '没有废弃字段'; then
  ok "verify：干净配置第 6 步打 ok"
else
  ng "verify：干净配置第 6 步没打 ok"
fi
unset SB_FAKE_LIVE_PORT SB_FAKE_QUIC SB_FAKE_UDP

#-- 审不了 ≠ 有问题 ---------------------------------------------------------
# 评审抓到的真 bug：check 退非 0 有两种含义 —— 内核拒绝了配置，和审查本身没做成
# （读不到文件、内核跑不起来、sudo 要密码）。原先不分开，于是任何让 check 跑不成的
# 原因都被报成「配置里有已移除字段」，而那个结论会一路传到 verify 的退出码上。
setup
UNREADABLE="$ROOT/unreadable.json"
cp "$FIX/good-http-client.json" "$UNREADABLE"; chmod 000 "$UNREADABLE"
audit --config "$UNREADABLE"
if [ "$CODE" != 0 ]; then
  ok "读不到配置：退出码非 0（实际 ${CODE}）"
else
  ng "读不到配置：竟然退 0 —— 一次没做成的检查被当成通过了"
fi
if inlog '没做成'; then
  ok "读不到配置：明说「审查没做成」"
else
  ng "读不到配置：没说清是审不了"
fi
if inlog 'removed' || inlog '已被本版本内核移除'; then
  ng "读不到配置：被误报成「配置里有已移除字段」"
else
  ok "读不到配置：没有误报成废弃/移除项"
fi
chmod 644 "$UNREADABLE"

# 上面那三条走的是 `[ -r "$cfg" ]` 那道前置检查。真正的兜底分支要另外驱动：
# 文件**可读**，check 却退非 0 且输出一个字都不像内核诊断（sudo 要密码、
# wrapper 脚本、SIP 拦截）。这一档才是评审抓到的那条 bug 的原始形状。
setup
export SB_FAKE_CHECK_NOISE=1
audit --config "$FIX/good-http-client.json"
if [ "$CODE" != 0 ] && inlog '没做成'; then
  ok "check 输出不像内核诊断：判为「审不了」，不是发现"
else
  ng "check 输出不像内核诊断：期望非 0 且说没做成，实际 ${CODE}"
fi
if inlog 'a terminal is required'; then
  ng "把 sudo 的报错整行当成了一条发现（正是评审抓到的那型误判）"
else
  ok "没有把非内核输出当成发现"
fi
unset SB_FAKE_CHECK_NOISE

# 同一条链在 verify 上：审不了不该让一次干净的 verify 退 2。
# （tests/verify.test.sh 里 $BIN 是空文件，走的正是这条「审不了」分支，
#   那 16 条全绿就是这条防线的另一半。）
setup
use_cfg good-http-client
: > "$ROOT/prefix/bin/sing-box"; chmod 755 "$ROOT/prefix/bin/sing-box"   # 内核问不出版本号
verify_run
if ! inlog '配置里有'; then
  ok "内核不可用：verify 第 6 步不报废弃项"
else
  ng "内核不可用：verify 把「审不了」报成了废弃项"
fi
if [ "$CODE" != 2 ] || ! grep -q '配置里有' "$LOG"; then
  ok "内核不可用：verify 没有因为第 6 步而退 2"
else
  ng "内核不可用：verify 因第 6 步误判退 2"
fi

#-- 14. SB_LOCKDIR：锁目录可隔离 -------------------------------------------
# 锁路径写死在 /tmp 时，测试之间、以及测试与 live 的 singbox 命令共用一把锁：
# 残留锁的 PID 恰好活着，acquire_lock 等 6 秒就 die。指到临时目录后各跑各的。
setup
echo 1 > "$SB_FAKE_STATE/running"
saved_lockdir="${SB_LOCKDIR:-}"
export SB_LOCKDIR="$ROOT/lock"
# (a) 变量真的被认：这个目录里放一把「持有者还活着」的锁，必须撞上
mkdir -p "$SB_LOCKDIR"; echo "$$" > "$SB_LOCKDIR/pid"
PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -n restart >"$LOG" 2>&1; CODE=$?
if [ "$CODE" != 0 ] && inlog '另一个 singbox 实例'; then
  ok "SB_LOCKDIR：指定目录里的活锁被看见了"
else
  ng "SB_LOCKDIR：没认这个变量（退出 ${CODE}，没撞上指定目录里的锁）"
fi
rm -rf "$SB_LOCKDIR"
# (b) 背靠背两次，各自拿锁各自放，都不该撞
for i in 1 2; do
  PATH="$FIXBIN:$PATH" "$SB" --prefix "$ROOT/prefix" -n restart >"$LOG" 2>&1; CODE=$?
  if [ "$CODE" = 0 ] && ! inlog '另一个 singbox 实例'; then
    ok "SB_LOCKDIR：第 ${i} 次 -n restart 干净（退 0）"
  else
    ng "SB_LOCKDIR：第 ${i} 次 -n restart 撞锁（退 ${CODE}）"
  fi
done
if [ -n "$saved_lockdir" ]; then export SB_LOCKDIR="$saved_lockdir"; else unset SB_LOCKDIR; fi

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
