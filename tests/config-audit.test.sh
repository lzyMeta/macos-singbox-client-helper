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

#-- 9. --deep：沙箱日志档。无网络时降级并明说，退出码按 A/B/C -------------
setup
export SB_FAKE_UDP=dead
audit --config "$FIX/good-http-client.json" --deep
ran "--deep 无网络"
if [ "$CODE" = 0 ] && inlog '沙箱日志档'; then
  ok "--deep 无网络：明说降级（沙箱日志档跳过），退出码按 A/B/C = 0"
else
  ng "--deep 无网络：没明说降级，或退出码 ${CODE} ≠ 0"
fi
unset SB_FAKE_UDP

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

#=============================================================================
# 迁移表（C 路）、去重、notice、covers —— docs/config-audit-migration-table.md
#=============================================================================
echo "验证 config audit 的迁移表档"

# 报告里点名某条发现：形如 "[<tier>/<sources>] <path>"。sources 用 + 连接。
# 这里用固定串而不是正则：路径里的 [ ] . 都是正则元字符。
hit() { grep -F -- "$1" "$LOG" >/dev/null; }

#-- T1. 隐式 HTTP client：check / schema 都看不见，只有表能报 -----------------
setup
audit --config "$FIX/bad-implicit-http-client.json"
ran "隐式 HTTP client"
if [ "$CODE" = 2 ]; then ok "隐式 HTTP client：退出 2"; else ng "隐式 HTTP client：期望 2，实际 $CODE"; fi
if hit 'table] route.rule_set[0]' ; then
  ok "隐式 HTTP client：点名 route.rule_set[0]，来源 table"
else
  ng "隐式 HTTP client：没点名 route.rule_set[0]（来源 table）"
fi
if hit 'route.rule_set[1]'; then
  ng "隐式 HTTP client：rule_set[1] 显式给了 http_client，却被点名了"
else
  ok "隐式 HTTP client：显式 http_client 的 rule_set[1] 没被点名"
fi
setup
audit --config "$FIX/good-explicit-http-clients.json"
ran "显式 http_clients"
if [ "$CODE" = 0 ] && ! inlog 'HTTP client'; then
  ok "顶层 http_clients 非空：隐式 client 一条不报，退 0（manager.go:42-44）"
else
  ng "顶层 http_clients 非空：仍报了隐式 client 或退出码 ${CODE} ≠ 0"
fi

#-- T2. 遗留地址过滤：键合法但用法废弃，match_response 开了的不许报 ------------
setup
audit --config "$FIX/bad-legacy-address-filter.json"
ran "遗留地址过滤"
if [ "$CODE" = 2 ]; then ok "遗留地址过滤：退出 2"; else ng "遗留地址过滤：期望 2，实际 $CODE"; fi
if hit 'deprecated/table] dns.rules[0]'; then
  ok "遗留地址过滤：点名无 match_response 的 dns.rules[0]"
else
  ng "遗留地址过滤：没点名 dns.rules[0]"
fi
if grep -F -- '] dns.rules[1]' "$LOG" | grep -v notice >/dev/null; then
  ng "遗留地址过滤：带 match_response: true 的 dns.rules[1] 被当成废弃用法点名了"
else
  ok "遗留地址过滤：match_response: true 的 dns.rules[1] 没被点名"
fi
# T12. 片段：两条都带 query_type，evaluate 那条的 server 是原规则的 dns-direct 而不是 dns.final
if inlog '建议写法' && [ "$(grep -c '"query_type"' "$LOG")" -ge 2 ]; then
  ok "地址过滤片段：打了「建议写法」且两条都限定 query_type"
else
  ng "地址过滤片段：缺「建议写法」或 query_type 不足两条（$(grep -c '"query_type"' "$LOG") 条）"
fi
if grep -F '"action": "evaluate"' "$LOG" | grep -F '"server": "dns-direct"' >/dev/null; then
  ok "地址过滤片段：evaluate 的 server 等于原规则的 dns-direct"
else
  ng "地址过滤片段：evaluate 的 server 不是原规则的 server（不许换成 dns.final）"
fi
if grep -F '"action": "evaluate"' "$LOG" | grep -F '"rewrite_ttl": 60' >/dev/null; then
  ok "地址过滤片段：原规则的 rewrite_ttl 搬到了 evaluate 那条"
else
  ng "地址过滤片段：rewrite_ttl 没搬到 evaluate 那条"
fi

#-- T3. store_rdrc：check / schema / table 三路全中，输出必须是一行 -------------
setup
audit --config "$FIX/bad-store-rdrc.json"
ran "store_rdrc"
n=$(grep -c 'experimental.cache_file.store_rdrc' "$LOG")
if [ "$n" = 1 ]; then
  ok "store_rdrc：三路命中合并成一行"
else
  ng "store_rdrc：期望一行，实际 ${n} 行（去重没做）"
fi
if hit 'deprecated/check+schema+table] experimental.cache_file.store_rdrc'; then
  ok "store_rdrc：来源栏 check+schema+table"
else
  ng "store_rdrc：来源栏不是 check+schema+table"
fi
if inlog 'migration/#migrate-store_rdrc'; then
  ok "store_rdrc：链接以表为准（check 档自带的假锚点被覆盖）"
else
  ng "store_rdrc：链接没有以表为准"
fi

#-- T4（前半）. Hysteria v1 调优字段：schema+table 能抓，run 不在来源里 ---------
setup
audit --config "$FIX/bad-hysteria-tuning.json"
ran "Hysteria 调优字段"
if [ "$CODE" = 2 ]; then ok "Hysteria 调优字段：退出 2"; else ng "Hysteria 调优字段：期望 2，实际 $CODE"; fi
if hit 'schema+table] outbounds[2].recv_window_conn' && hit 'schema+table] outbounds[2].disable_mtu_discovery'; then
  ok "Hysteria 调优字段：两处都点名，来源 schema+table"
else
  ng "Hysteria 调优字段：没有以 schema+table 点名两处"
fi
if grep -F 'outbounds[2]' "$LOG" | grep -q 'run'; then
  ng "Hysteria 调优字段：来源里出现了 run（内核对它不告警）"
else
  ok "Hysteria 调优字段：来源不含 run"
fi
if inlog '内核不会告警'; then ok "Hysteria 调优字段：说明了内核不会告警"; else ng "Hysteria 调优字段：缺「内核不会告警」说明"; fi

#-- T5. notice：只命中行为变更，退 0，带官方链接 -------------------------------
setup
audit --config "$FIX/notice-query-type.json"
ran "notice"
if [ "$CODE" = 0 ]; then ok "notice：退出 0（不影响退出码）"; else ng "notice：期望 0，实际 $CODE"; fi
if hit 'notice/table] dns.rules[0]'; then ok "notice：点名 dns.rules[0]"; else ng "notice：没点名 dns.rules[0]"; fi
if inlog 'migration/#ip_version-and-query_type-behavior-changes-in-dns-rules'; then
  ok "notice：带官方链接"
else
  ng "notice：缺官方链接"
fi

#-- T6. covers：内核 minor 高于表就提示一行，退出码不变 --------------------------
setup 1.15.3
audit --config "$FIX/good-http-client.json"
ran "covers 1.15.3"
if inlog '迁移表只覆盖到 1.14.0' && [ "$CODE" = 0 ]; then
  ok "covers：内核 1.15.3 时提示「迁移表只覆盖到 1.14.0」，退出码仍 0"
else
  ng "covers：内核 1.15.3 时没提示，或退出码 ${CODE} ≠ 0"
fi
setup 1.14.9
audit --config "$FIX/good-http-client.json"
ran "covers 1.14.9"
if inlog '迁移表只覆盖到'; then
  ng "covers：内核 1.14.9 也提示了（该按 minor 比）"
else
  ok "covers：内核 1.14.9 不提示"
fi

#-- T11. strategy：ipv4_only 给片段，prefer_* 不给 ------------------------------
setup
audit --config "$FIX/bad-dns-strategy.json"
ran "strategy ipv4_only"
if [ "$CODE" = 2 ] && hit 'schema+table] dns.rules[0].strategy'; then
  ok "strategy：schema+table 点名 dns.rules[0].strategy，退 2"
else
  ng "strategy：没以 schema+table 点名（退 ${CODE}）"
fi
if inlog '建议写法' && grep -F '"query_type": ["AAAA"]' "$LOG" >/dev/null; then
  ok "strategy ipv4_only：片段含 query_type: [\"AAAA\"]"
else
  ng "strategy ipv4_only：缺片段或片段没限定 AAAA"
fi
if inlog '无 migration 章节'; then ok "strategy：注明了 v1.14.0 无 migration 章节"; else ng "strategy：没注明死链"; fi
setup
audit --config "$FIX/bad-dns-strategy-prefer.json"
ran "strategy prefer_ipv4"
if [ "$CODE" = 2 ] && ! inlog '建议写法' && inlog '删掉即可'; then
  ok "strategy prefer_ipv4：不给片段，只说删掉即可"
else
  ng "strategy prefer_ipv4：给了片段，或没说「删掉即可」（退 ${CODE}）"
fi

#-- T13. 表里的 migration/# 锚点必须在 v1.14.0 的清单里 --------------------------
# 直接查脚本源码：表就内置在里面。清单来自 tag v1.14.0 的 docs/migration.md（见 fixture 头注）。
n_anchor=$(grep -o 'sagernet\.org/migration/#[A-Za-z0-9_-]*' "$SB" | sort -u | wc -l | tr -d ' ')
if [ "$n_anchor" -ge 6 ]; then
  ok "迁移链接：源码里能抓到 ${n_anchor} 个 migration/# 锚点（链接是整段字面量）"
else
  ng "迁移链接：只抓到 ${n_anchor} 个锚点 —— 链接被拆成字符串拼接了？下一条断言会恒绿"
fi
bad_anchor=""
for a in $(grep -o 'sagernet\.org/migration/#[A-Za-z0-9_-]*' "$SB" | sed 's|.*#||' | sort -u); do
  grep -qx "$a" "$FIX/migration-anchors.txt" || bad_anchor="$bad_anchor $a"
done
if [ -z "$bad_anchor" ]; then
  ok "迁移链接：所有 migration/# 锚点都在 v1.14.0 清单内"
else
  ng "迁移链接：清单外的锚点（死链）：${bad_anchor}"
fi

#-- T7. --deep：假内核把 SB_FAKE_RUN_LOG 吐到 stderr，3 条 WARN 全部进报告，来源 run ---
setup
export SB_FAKE_UDP=alive SB_FAKE_RUN_LOG="$FIX/sandbox-run.log"
audit --config "$FIX/good-http-client.json" --deep
ran "--deep 有日志"
if [ "$CODE" = 2 ]; then ok "--deep：沙箱日志里的 WARN 让退出码变 2"; else ng "--deep：期望 2，实际 ${CODE}"; fi
if hit 'deprecated/run] implicit_http_client' && hit 'deprecated/run] dns_rule_strategy' && hit 'deprecated/run] legacy_address_filter'; then
  ok "--deep：3 条 WARN 全部出现，来源 run（配置里离线定位不到，以条目 id 为路径）"
else
  ng "--deep：3 条 WARN 没有全部以来源 run 出现"
fi
if inlog '沙箱建链成功'; then ok "--deep：沙箱真的起了（不是走降级）"; else ng "--deep：沙箱没起"; fi
# 内核 WARN 自带的 strategy 链接是死链，报告里必须以表为准
if inlog 'sagernet\.org/migration/#migrate-dns-rule-action-strategy-to-rule-items'; then
  ng "--deep：strategy 那条把内核 WARN 里的死链原样带出来了（应以表为准覆盖）"
else
  ok "--deep：strategy 的死链被表覆盖"
fi
unset SB_FAKE_RUN_LOG SB_FAKE_UDP

#-- T3（--deep）. store_rdrc 四路全中仍是一行：check+schema+table+run --------------
setup
printf 'WARN[0000] `store_rdrc` cache file option is deprecated in sing-box 1.14.0 and will be removed in sing-box 1.16.0, checkout documentation for migration: https://sing-box.sagernet.org/migration/#migrate-store_rdrc\n' > "$ROOT/rdrc.log"
export SB_FAKE_UDP=alive SB_FAKE_RUN_LOG="$ROOT/rdrc.log"
audit --config "$FIX/bad-store-rdrc.json" --deep
ran "store_rdrc --deep"
if [ "$(grep -c 'experimental.cache_file.store_rdrc' "$LOG")" = 1 ] && hit 'deprecated/check+schema+table+run] experimental.cache_file.store_rdrc'; then
  ok "store_rdrc --deep：四路全中合并成一行，来源 check+schema+table+run"
else
  ng "store_rdrc --deep：没有合并成一行 check+schema+table+run"
fi
unset SB_FAKE_RUN_LOG SB_FAKE_UDP

#-- T4（后半）. --deep 喂一份没有 Hysteria 的日志，D 路不能给它添 run ---------------
setup
export SB_FAKE_UDP=alive SB_FAKE_RUN_LOG="$FIX/sandbox-run.log"
audit --config "$FIX/bad-hysteria-tuning.json" --deep
ran "Hysteria --deep"
if hit 'schema+table] outbounds[2].recv_window_conn' && ! grep -F 'outbounds[2]' "$LOG" | grep -q 'run'; then
  ok "Hysteria --deep：来源仍是 schema+table，D 路没误报"
else
  ng "Hysteria --deep：D 路给 Hysteria 字段添了 run，或点名丢了"
fi
unset SB_FAKE_RUN_LOG SB_FAKE_UDP

#-- T7b. 规则集地址过滤：离线只能 notice，沙箱日志定性后升为 deprecated ------------
setup
printf 'WARN[0000] Legacy Address Filter Fields in DNS rules is deprecated in sing-box 1.14.0 and will be removed in sing-box 1.16.0, checkout documentation for migration: https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching\n' > "$ROOT/af.log"
cp "$FIX/good-http-client.json" "$ROOT/rs.json"
python3 - "$ROOT/rs.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["dns"] = {"servers": [{"type": "udp", "tag": "dns-direct", "server": "223.5.5.5"}],
            "rules": [{"rule_set": "geoip-cn", "action": "route", "server": "dns-direct"}], "final": "dns-direct"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
audit --config "$ROOT/rs.json"
if [ "$CODE" = 0 ] && hit 'notice/table] dns.rules[0]'; then
  ok "规则集地址过滤：离线只出 notice，退 0"
else
  ng "规则集地址过滤：离线没有出 notice 或退出码 ${CODE} ≠ 0"
fi
export SB_FAKE_UDP=alive SB_FAKE_RUN_LOG="$ROOT/af.log"
audit --config "$ROOT/rs.json" --deep
if [ "$CODE" = 2 ] && hit 'deprecated/table+run] dns.rules[0]'; then
  ok "规则集地址过滤：--deep 定性后升为 deprecated，来源 table+run，退 2"
else
  ng "规则集地址过滤：--deep 没有把 notice 升为 deprecated（退 ${CODE}）"
fi
# 反向定性：沙箱建链成功、日志里没有这条 WARN → 规则集不含 ip_cidr，notice 该撤掉，
# 不能还留着一句「用 --deep 定性」
export SB_FAKE_RUN_LOG="$FIX/sandbox-run.log"
python3 - "$FIX/sandbox-run.log" "$ROOT/no-af.log" <<'PY'
import sys
open(sys.argv[2], "w").writelines(l for l in open(sys.argv[1]) if "Address Filter" not in l)
PY
export SB_FAKE_RUN_LOG="$ROOT/no-af.log"
audit --config "$ROOT/rs.json" --deep
if inlog '沙箱建链成功' && ! grep -F '] dns.rules[0]' "$LOG" >/dev/null; then
  ok "规则集地址过滤：--deep 建链成功且内核没告警 → notice 撤掉"
else
  ng "规则集地址过滤：--deep 已定性为「不是遗留用法」，notice 却还在"
fi
unset SB_FAKE_RUN_LOG SB_FAKE_UDP

#=============================================================================
# 改写层：3 条纯键名规则共用一张规则表 —— docs/config-audit-migration-table.md
#=============================================================================
echo "验证 config audit --apply 的三条规则"

# flatdiff <before> <after>：独立于实现的扁平结构 diff，每行 "path<TAB>before<TAB>after"
# （缺失记作 MISS）。不复用实现里的白名单校验器——那等于拿被测对象给自己打分。
flatdiff() {
  python3 - "$1" "$2" <<'PY'
import json, sys
def flat(o, p="", out=None):
    if out is None: out = {}
    if isinstance(o, dict):
        for k, v in o.items(): flat(v, (p + "." + k) if p else k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o): flat(v, "%s[%d]" % (p, i), out)
    else: out[p] = o
    return out
a = flat(json.load(open(sys.argv[1]))); b = flat(json.load(open(sys.argv[2])))
for k in sorted(set(a) | set(b)):
    if a.get(k, "MISS") != b.get(k, "MISS"):
        print("%s\t%s\t%s" % (k, json.dumps(a.get(k, "MISS")), json.dumps(b.get(k, "MISS"))))
PY
}

#-- T8. store_rdrc：true 且无 store_dns → 改名 store_dns: true ---------------------
setup
use_cfg bad-store-rdrc
cp "$(livecfg)" "$ROOT/before.json"
export SB_FAKE_UDP=dead
echo 1 > "$SB_FAKE_STATE/running"
audit --apply
if [ "$CODE" = 0 ]; then ok "store_rdrc --apply：退出 0"; else ng "store_rdrc --apply：期望 0，实际 ${CODE}"; fi
D=$(flatdiff "$ROOT/before.json" "$(livecfg)")
WANT=$(printf 'experimental.cache_file.store_dns\t"MISS"\ttrue\nexperimental.cache_file.store_rdrc\ttrue\t"MISS"')
if [ "$D" = "$WANT" ]; then
  ok "store_rdrc --apply：结构 diff 恰好是 store_rdrc 删、store_dns 增，值 true"
else
  ng "store_rdrc --apply：diff 不是预期的那两行" "$D"
fi
audit
if [ "$CODE" = 0 ]; then ok "store_rdrc --apply 后重跑发现层：归零"; else ng "store_rdrc --apply 后重跑：退 ${CODE}"; fi

setup
use_cfg bad-store-rdrc-has-store-dns
cp "$(livecfg)" "$ROOT/before.json"
export SB_FAKE_UDP=dead
echo 1 > "$SB_FAKE_STATE/running"
audit --apply
D=$(flatdiff "$ROOT/before.json" "$(livecfg)")
WANT=$(printf 'experimental.cache_file.store_rdrc\ttrue\t"MISS"')
if [ "$CODE" = 0 ] && [ "$D" = "$WANT" ]; then
  ok "store_rdrc 已有 store_dns：只删不增"
else
  ng "store_rdrc 已有 store_dns：diff 不是只删 store_rdrc（退 ${CODE}）" "$D"
fi

#-- T9. independent_cache：只删 ------------------------------------------------------
setup
use_cfg bad-independent-cache
cp "$(livecfg)" "$ROOT/before.json"
export SB_FAKE_UDP=dead
echo 1 > "$SB_FAKE_STATE/running"
audit --apply
D=$(flatdiff "$ROOT/before.json" "$(livecfg)")
WANT=$(printf 'dns.independent_cache\ttrue\t"MISS"')
if [ "$CODE" = 0 ] && [ "$D" = "$WANT" ]; then
  ok "independent_cache --apply：只删 dns.independent_cache"
else
  ng "independent_cache --apply：diff 不是只删那一个键（退 ${CODE}）" "$D"
fi

#-- T10. 三条规则同时命中：确认提示逐条列命中数；值映射被篡改时第 1 道拒绝 -------------
setup
use_cfg bad-three-rules
cp "$(livecfg)" "$ROOT/before.json"
export SB_FAKE_UDP=dead
echo 1 > "$SB_FAKE_STATE/running"
audit --apply
if [ "$CODE" = 0 ]; then ok "三条规则 --apply：退出 0"; else ng "三条规则 --apply：期望 0，实际 ${CODE}"; fi
if inlog 'download_detour.*1 处' && inlog 'independent_cache.*1 处' && inlog 'store_rdrc.*1 处'; then
  ok "三条规则 --apply：确认提示逐条列出三条规则各 1 处"
else
  ng "三条规则 --apply：确认提示没有逐条列出命中数"
fi
D=$(flatdiff "$ROOT/before.json" "$(livecfg)")
if [ "$(printf '%s\n' "$D" | wc -l | tr -d ' ')" = 5 ] \
   && printf '%s\n' "$D" | grep -q '^route.rule_set\[0\].http_client.detour	"MISS"	"vpstrans"$' \
   && printf '%s\n' "$D" | grep -q '^experimental.cache_file.store_dns	"MISS"	true$'; then
  ok "三条规则 --apply：diff 恰好 5 行（1 处 detour 搬移 + 2 处删 + 1 处改名）"
else
  ng "三条规则 --apply：diff 不是预期的 5 行" "$D"
fi
# 值映射被篡改：store_rdrc: true 却写成了 store_dns: false —— 第 1 道必须拒
setup
use_cfg bad-three-rules
export SB_FAKE_UDP=dead
python3 - "$FIX/bad-three-rules.json" "$ROOT/tampered.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["route"]["rule_set"][0]["http_client"] = {"detour": d["route"]["rule_set"][0].pop("download_detour")}
d["dns"].pop("independent_cache")
d["experimental"]["cache_file"].pop("store_rdrc")
d["experimental"]["cache_file"]["store_dns"] = False
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
export SB_FAKE_MIGRATED="$ROOT/tampered.json"
audit --apply
if [ "$CODE" != 0 ] && inlog '验收 1/4' && ! inlog '验收 2/4'; then
  ok "值映射篡改（store_dns: false）：第 1 道拒绝，没走到第 2 道"
else
  ng "值映射篡改：没被第 1 道拒绝（退 ${CODE}）"
fi
unset SB_FAKE_MIGRATED SB_FAKE_UDP

#=============================================================================
# 合并逻辑的两个边界（review 发现）
#=============================================================================
echo "验证合并逻辑的边界"

#-- R1. 表外的 D 路 WARN 两条都得出现：路径 - 不能当去重键 -----------------------
setup
printf 'WARN[0000] foo_option is deprecated in sing-box 1.15.0 and will be removed in sing-box 1.17.0.\nWARN[0000] bar_option is deprecated in sing-box 1.15.0 and will be removed in sing-box 1.17.0.\n' > "$ROOT/two.log"
export SB_FAKE_UDP=alive SB_FAKE_RUN_LOG="$ROOT/two.log"
audit --config "$FIX/good-http-client.json" --deep
ran "表外 WARN 两条"
if inlog 'foo_option' && inlog 'bar_option' && inlog '2 项已废弃'; then
  ok "表外 WARN：两条都出现，计数 2"
else
  ng "表外 WARN：第二条被路径 - 吞掉了（计数 $(grep -o '[0-9]* 项已废弃' "$LOG"))"
fi
unset SB_FAKE_RUN_LOG SB_FAKE_UDP

#-- R2. unknown field X 要贴到 B 路的路径上：一行、removed/check+schema -------------
setup
cp "$FIX/good-http-client.json" "$ROOT/bogus.json"
python3 - "$ROOT/bogus.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["experimental"]["cache_file"]["bogus_key"] = True
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
export SB_FAKE_CHECK_FAIL="all:$VER" SB_FAKE_UNKNOWN_FIELD=bogus_key
audit --config "$ROOT/bogus.json"
ran "unknown field 与 schema 同键"
if [ "$CODE" = 1 ] && hit 'removed/check+schema] experimental.cache_file.bogus_key' \
   && [ "$(grep -c 'bogus_key' "$LOG")" = 1 ]; then
  ok "unknown field：与 schema 的同一键合并成一行 removed/check+schema"
else
  ng "unknown field：没与 schema 的同一键合并（退 ${CODE}，bogus_key 出现 $(grep -c 'bogus_key' "$LOG") 次）"
fi
unset SB_FAKE_CHECK_FAIL SB_FAKE_UNKNOWN_FIELD

#-- R3. 直接地址过滤规则与 rule_set 规则共存：内核那条 WARN 全局只打一次（dns/router.go:156
#   common.Any），说明不了 rule_set 那条——既不能升 deprecated，也不能撤 notice ------------
setup
cp "$FIX/good-http-client.json" "$ROOT/mix.json"
python3 - "$ROOT/mix.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["dns"] = {"servers": [{"type": "udp", "tag": "dns-direct", "server": "223.5.5.5"}],
            "rules": [{"domain_suffix": ["cn"], "ip_is_private": True, "action": "route", "server": "dns-direct"},
                      {"rule_set": "geoip-cn", "action": "route", "server": "dns-direct"}], "final": "dns-direct"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
printf 'WARN[0000] Legacy Address Filter Fields in DNS rules is deprecated in sing-box 1.14.0 and will be removed in sing-box 1.16.0, checkout documentation for migration: https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching\n' > "$ROOT/af.log"
export SB_FAKE_UDP=alive SB_FAKE_RUN_LOG="$ROOT/af.log"
audit --config "$ROOT/mix.json" --deep
ran "直接过滤 + rule_set 共存"
if hit 'deprecated/table+run] dns.rules[0]' && hit 'notice/table] dns.rules[1]'; then
  ok "共存：WARN 贴到直接规则 dns.rules[0]，rule_set 的 dns.rules[1] 维持 notice（既不升也不撤）"
else
  ng "共存：dns.rules[1] 的 notice 被撤掉或被误升（全局一次的 WARN 定性不了它）"
fi
unset SB_FAKE_RUN_LOG SB_FAKE_UDP

echo
printf '通过 %d，失败 %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
