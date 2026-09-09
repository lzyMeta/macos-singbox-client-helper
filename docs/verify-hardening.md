# cmd_verify 收紧：消除静默跳过，QUIC 改为真探测，第 5 步补上判据

## 问题

`cmd_verify`（`singbox.sh:1006-1084`）五步里有 **5 处软分支**，它们的共同毛病是
**「测不了」和「测过了」在终端上长得一样**——都不打 ✗，退出码都是 0：

| 位置 | 现状 | 毛病 |
|---|---|---|
| 第 2 步 | `ipinfo.io` 取不到 → `warn` 跳过分流判断 | 分流到底生效没有，无结论 |
| 第 3 步 | 未装 `dig` → `dim` 跳过整步 | DNS 防泄漏整步不做 |
| 第 4 步 | curl 不支持 http3 → `dim` 跳过 | **本机 curl 8.7.1 (SecureTransport) 就是不支持，这半步从来没真跑过** |
| 第 5 步 | `cip.cc` 取不到 → 只 `info` | 整步没有任何断言，永远不会失败 |
| 第 5 步 | 拿不到默认网关 → `if [ -n "$gw" ]` 静默不检查 | 连打印都没有，用户不知道漏了 |

`docs/safe-update.md:169-197` 已经把这几条记录在案，当时的结论是「维持现状」，理由是
**这些分支多数不是失败而是测不了，把测不了也算失败会让每次 `singbox update` 都在阶段 3 回滚**。
那条理由现在不成立了：

1. 第 3 步的 `dig` 其实是 macOS 自带的 `/usr/bin/dig`，同目录还有 `host` / `nslookup` /
   `dscacheutil`，加上脚本已硬依赖的 `python3`——**根本不缺解析手段**，只是代码只认 `dig` 一个。
2. 第 4 步的 HTTP/3 不必依赖 curl 的编译选项，`python3` 直接发 QUIC 版本协商包就能测。
3. 「回滚」这个后果可以拆开：DNS 泄漏 / QUIC 没挡住 / 国内直连失效都是**路由策略**问题，
   回滚旧内核换不回来。分档之后，收紧判定与「不误回滚」不再冲突。

同一处 `docs/safe-update.md:190-197` 还预留了第 5 步的判据（带真机数据：SOCKS 出口
`<vps-socks-ip>` vs `cip.cc` 报的 `<home-cn-ip>` 上海电信），注明「超出本 spec 范围，**另开一条**」。
这份 spec 就是那一条。

## 决定

`cmd_verify` 引入**两档失败**，并把 5 处静默跳过全部消除：

**分档.** 现有 `VERIFY_BAD` / `vbad()`（`singbox.sh:95-99`）保留为**链路档**；新增
`VERIFY_POLICY_BAD` / `vpbad()` 为**策略档**。退出码约定：

| 退出码 | 含义 | 升级阶段 3 的动作 |
|---|---|---|
| `0` | 全过 | 通过 |
| `1` | 链路档有失败（含第 1 步的 `return 1`） | 重试一轮，仍失败则回滚 |
| `2` | 仅策略档有失败 | **不回滚**，`warn` 后放行 |

两档都失败时返回 `1`（链路优先）。`_sb_verify_rounds`（`singbox.sh:1576-1588`）改为读退出码
而非布尔：`2` 直接当通过返回，只有 `1` 才进重试与回滚。

**逐步的新判定：**

- **第 1 步**（节点链路，链路档）：不变。
- **第 2 步**（出口 IP 分流，链路档）：`ipinfo.io` **不换域名**——它被写死在
  `config/config.example.json:201` 的 `vpsre` 社交组里，是分流判定的固定参照物
  （`docs/best-practices.md:873`），换端点等于改配置。改为**同一端点重试 3 次**，仍取不到则
  硬失败、计入**策略档**——第三方站点可用性不是内核问题，回滚换不回来。
  （**已拍板：lzyMeta，2026-09-04**。此处两条约束字面上会打架：「取不到即硬失败」加上
  「第 2 步属链路档」等于让 `ipinfo.io` 抽一下就回滚一次好升级。按分档**原则**——
  策略/环境问题不回滚——判给策略档。）
  「兜底取不到 IP」「两个出口相同」仍是链路档，不变。
- **第 3 步**（DNS 防泄漏，策略档）：解析手段降级为 4 级链，**任一级拿到 A 记录即采用**：
  `dig +short` → `host -W 3` → `dscacheutil -q host -a name` → `python3 socket.getaddrinfo`。
  四级全废才硬失败（此时报的是「本机没有任何可用解析手段」，与污染分开报）。
  污染名单沿用现有的 `157.240.*` / `31.13.*` / 空结果，命中则硬失败。
- **第 4 步**（QUIC，策略档）：**弃用 `curl --http3`**，改为 `python3` 内联的 QUIC
  版本协商探测——构造 `version=0x1a2a3a4a`（保留版本）的 QUIC long-header Initial 包、
  填充至 1200 字节，UDP 发往 `cloudflare-quic.com:443`。按 RFC 9000 §6，服务端收到未知版本
  **必须**回 Version Negotiation 包（`version=0x00000000`）：
  - 收到回包 → **QUIC 未被阻断** → 硬失败（原为 `warn`）
  - 全部端点超时 → 已阻断 → `ok`
  端点配 2 个（`cloudflare-quic.com:443`、`quic.rocks:4433`），**任一收到回包即判未阻断**。
  这两个域名不在任何路由规则里，加备胎不动配置。IPv6 判定不变，仍是链路档。
- **第 5 步**（国内直连与局域网，策略档）：整步从「只打印」变成**有断言**。
  - `cip.cc` 加备胎（`myip.ipip.net`、`ip.3322.net`），逐个试，统一用正则抽第一个 IPv4；
    **全挂才**硬失败。
  - **新硬失败**：抽出的国内 IP **等于第 1 步的 SOCKS 出口 IP** → 国内直连没生效，全被代理接走。
  - 拿不到默认网关 → 硬失败（不再静默跳过）。
  - `ping` 网关不通 → 硬失败（原为 `warn`），连试 3 次全丢才判失败，避开无线抖动。

**测试可见性.** QUIC 探测是内联 `python3`，PATH 桩拦不住。为此加一个测试后门环境变量
`SB_FAKE_QUIC=blocked|open`：设置时探测函数直接返回预设结果，不发包。这是让第 4 步可测的
唯一手段，必须在代码注释里写明它只服务于测试。

## 不在范围内

- **不动任何路由规则或配置模板。** `config/config.example.json` 一个字不改：`ipinfo.io` 继续
  固定在 `vpsre`，也不新增 `udp` + `443` + `reject` 规则。这份 spec 只改**检查**，不改**策略**。
- **不做配置静态核对。** 不从 `$CFG` 里找禁 QUIC 规则来辅助判断——第 4 步的判据只有实测探测一条。
- **`cip.cc` 只跟第 1 步的 SOCKS 出口比**，不跟第 2 步的兜底出口 / 社交出口比。
  （代价已知：「国内规则排在了兜底之后」这类故障若恰好走兜底出口，这条比不出来。已拍板接受。）
- **不给 `verify` 加新的 CLI 开关**（`--strict` / `--link-only` 之类）。分档是内部的，
  调用方只看退出码。
- **不引入任何新的外部依赖。** 不要 `brew install bind`、不要 `aioquic`、不要第三方 curl。
  新增能力全部由 `python3` 标准库和 macOS 自带工具提供。
- **不碰第 1 步、不碰 IPv6 判定、不碰 `cmd_update` 的四阶段结构**——`cmd_update` 只改
  `_sb_verify_rounds` 里读退出码的那几行。
- **不做浏览器侧验证的自动化**（`dnsleaktest.com` 的 Extended Test、`test-ipv6.com`）。
  这些仍是 `dim` 提示，它们本来就不是跳过的检查项，而是给人看的补充手段。
- **不改 `cmd_syscheck` / `cmd_doctor` / `cmd_status`。**

## 受影响的文件与接口

**`singbox.sh`（唯一的实现文件）**

| 位置 | 改动 |
|---|---|
| `:95-99` | `VERIFY_BAD` / `vbad()` 旁新增 `VERIFY_POLICY_BAD` / `vpbad()`，注释说明两档的判据 |
| `:1006-1084` `cmd_verify` | 五步的判定按上表重写；末尾按两个计数器返回 `0` / `1` / `2` |
| 新 helper | `_sb_resolve_a`（4 级 DNS 降级链）、`_sb_quic_open`（QUIC VN 探测，含 `SB_FAKE_QUIC` 后门）、`_sb_fetch_cn_ip`（`cip.cc` + 备胎，抽 IPv4） |
| `:1576-1588` `_sb_verify_rounds` | `cmd_verify && return 0` 改为捕获退出码：`0`/`2` 返回 0，`1` 才重试与回滚 |
| `:805` | install 第 7 步 `[ "$DRY" = 0 ] && cmd_verify || true` —— 退出码本就被吞，行为不变，确认无需改 |
| `:1988` `:2019` | 帮助文本补一行退出码语义 |

**`tests/fixtures/bin/`（PATH 桩）**

- `dig`：加 `SB_FAKE_DIG_FAIL=1`（输出空并 `exit 1`），用来驱动降级链
- **新增** `host`、`dscacheutil`：同样受 `SB_FAKE_*_FAIL` 驱动
- `curl`：新增 `myip.ipip.net` / `ip.3322.net` 两条 URL 分支；加 `SB_FAKE_CN_IP=<ip>` 让 `cip.cc`
  能返回等于 SOCKS 出口（`1.2.3.4`）的值，用来测新硬失败
- `netstat`：加 `SB_FAKE_NO_GW=1`（默认路由那行不输出）
- `ping`：加 `SB_FAKE_PING_FAIL=1`

**`tests/verify.test.sh`（新增）**，纳入 `tests/run.sh` 的通配。

**文档同步**（这次改的正是需求来源本身，必须同步，否则下次又会被当成「已拍板维持现状」）：

- `docs/safe-update.md:169-197`：那张软分支表全部作废，改写为两档表 + 退出码约定；
  190-197 的「另开一条」标注改为「已由 `docs/verify-hardening.md` 兑现」
- `docs/script-usage.md`（`verify` 一节，约 `:287`）：退出码语义、新的失败原因与排查指引
- `docs/best-practices.md` 5.8 / 5.9（约 `:1315-1370`）：QUIC 与国内直连的判据说明跟上
- `README.md`：`verify` 的一句话描述

## 待定问题

1. ~~**QUIC 探测全部超时时，「已阻断」与「本机 UDP 出网整体不通」区分不了。**~~
   **已解决**（v1.1.0）。按当初设想的方向做了：新增 `_sb_udp_alive` 对照组，
   发一个标准 DNS 查询到公共解析器的 udp/53。判据变成三分支——
   QUIC 通 → 未阻断（`vpbad`）；QUIC 不通但对照通 → 已阻断（`ok`）；
   两个都不通 → **这一步没有结论**（`vpbad`），与第 3、5 步「取不到数据就是没有结论」一致。
   
   没有改成「多试几次」：QUIC 被挡住是**期望的成功路径**，表现恰恰是全部超时，
   加重试会给每一次正常的 `verify` 平白加十几秒，还要乘 `_sb_verify_rounds` 的两轮。
   
   ⚠️ 对照组证明的是「UDP 有来回」，不是「UDP 直出」——配置里的 DNS 劫持规则
   完全可能把这个查询接管掉再代答。用作「本机 UDP 是不是整个废了」的判据够用，别当成别的。
   测试后门 `SB_FAKE_UDP=alive|dead`，与 `SB_FAKE_QUIC` 同理。
2. **真机验证要你自己跑。** `CLAUDE.md` 写明本机有 live sing-box，`./singbox.sh` 的
   install/start/restart 等已 deny。下面「验证」的第 2 段必须由人执行。

## 验证

**第 1 段：机械验证（可自动跑，是这份 spec 的验收线）**

```
./singbox-selfcheck.sh && ./tests/run.sh
```

`tests/verify.test.sh` 至少要覆盖这些断言（每条都验**退出码**，不只看输出）：

| # | 场景 | 期望 |
|---|---|---|
| 1 | 全部桩正常 | 退出码 `0`，五步全绿 |
| 2 | `SB_FAKE_VERIFY_FAIL=all` | 退出码 `1`（第 1 步链路档） |
| 3 | `SB_FAKE_DIG_FAIL=1` | 退出码 `0` —— 降级到 `host` 后照样完成检查，**不跳过** |
| 4 | `dig`/`host`/`dscacheutil` 桩全废 | 退出码 `2`，报「无可用解析手段」，且与污染报错文案不同 |
| 5 | `dig` 桩返回 `157.240.1.1` | 退出码 `2`，报疑似污染 |
| 5b | `dig` 桩返回 `1.2.3.4,157.240.9.9,5.6.7.8` | 退出码 `2` —— 污染 IP 不在第一条也要抓到 |
| 5c | `dig` 桩返回 `131.13.5.5` | 退出码 `0` —— 不许因为子串 `31.13.` 而误报 |
| 6 | `SB_FAKE_QUIC=open` | 退出码 `2`，第 4 步打 ✗（**不再是 warn，也不再跳过**） |
| 7 | `SB_FAKE_QUIC=blocked` + `SB_FAKE_UDP=alive` | 第 4 步 `ok` |
| 7b | `SB_FAKE_QUIC=blocked` + `SB_FAKE_UDP=dead` | 退出码 `2`，报「UDP 整体出不去…没有结论」，**不再假绿** |
| 8 | `SB_FAKE_CN_IP=1.2.3.4`（等于 SOCKS 出口） | 退出码 `2`，报国内直连失效 |
| 9 | `cip.cc` 桩失败但备胎可用 | 退出码 `0` |
| 10 | `cip.cc` 与两个备胎全失败 | 退出码 `2` |
| 11 | `SB_FAKE_NO_GW=1` | 退出码 `2`（**不再静默跳过**） |
| 12 | `SB_FAKE_PING_FAIL=1` | 退出码 `2`（原为 warn），且确认重试了 3 次 |
| 13 | 仅策略档失败时跑 `cmd_update` 阶段 3 | **不回滚**，`$BIN` 仍是新版本、`$BIN.prev` 仍在 |
| 14 | 链路档失败时跑 `cmd_update` 阶段 3 | 回滚，`$BIN` 换回旧版本 |

第 13/14 条最关键——它们是「分档」这个决定唯一能被机械证伪的地方，
写法照抄 `tests/update.test.sh` 现有的状态机断言。

`singbox-selfcheck.sh` 的 12 项静态检查同时是硬约束，新代码必须过：bash 3.2（无 `declare -A`
/ `${x^^}` / `mapfile`）、BSD 工具链（无 `sed -i `、`readlink -f`、`grep -oP`）、
变量后紧跟全角字符要写 `${VAR}中文`、数组在 `set -u` 下不裸展开。内联 `python3` 用
`<<'PY'` heredoc（`sock_addr:196` 与 `cmd_debug` 有现成写法）。

**第 2 段：真机验证（人工，脚本已 deny）—— 已于 2026-09-05 由 lzyMeta 执行，全部通过**

实测输出（节选）：五步全部打印判定结果，**一处「跳过」都没有**，`exit=0`。

| 步 | 实测 | 说明 |
|---|---|---|
| 1 | SOCKS 出口 `<vps-socks-ip>` | — |
| 2 | 社交组 `<vpsre-exit-ip>` AS7018 AT&T | 与兜底不同，分流生效 |
| 3 | `142.251.156.119` 等 3 条 | 走的是第 1 级 `dig`；后三级真机上没被走到（`verify.test.sh` 已逐级驱动） |
| 4 | `✓ QUIC 已阻断` | 两个端点都超时 |
| 5 | `<home-cn-ip>` 上海电信 | 与 SOCKS 出口不同 → 国内直连生效。与本文档开头记录的真机数据一致 |

**第 4 步的反证也跑了**：注释掉配置里 `udp + 443 + reject` 那条规则、`restart` 后重跑，
得到 `exit=2` 且第 4 步打 ✗。这条是第 4 步唯一的证伪手段——探测坏了（包构造错、UDP 发不
出去、异常被吞）和 QUIC 真被挡住，输出完全一样。同一台机器能产出两种结果，才说明那半步是活的。

⚠️ 评审时列出的存疑项「备胎端点 `quic.rocks:4433` 不被 `udp + 443 + reject` 覆盖，
可能在配置正确的机器上恒报未阻断」—— **本机不复现**，两个端点都超时。

「待定问题 1」（全超时时「已阻断」与「本机 UDP 整体不通」分不开）**收窄但未消除**：
反证说明规则去掉后包出得去，即这张网的 UDP/443 本身是通的，那么规则在时的超时可归因于
规则。换一张网仍然无从区分。

**原始验证步骤（重跑时照此）**

```
./singbox.sh verify; echo "exit=$?"
```

- 正常状态下应 `exit=0`，且**第 3、4、5 步都真的打印了判定结果**，一处 `dim ... 跳过` 都不该出现。
- 第 4 步应报「QUIC 已阻断」。手工反证：临时注释掉配置里禁 QUIC 那条规则、`restart` 后重跑，
  应变成 `exit=2` 且第 4 步打 ✗。
- 第 5 步打印的国内 IP 应是本地城市与运营商，且与第 1 步的 SOCKS 出口不同。

## 实现计划

（由 `/sdlc-kit:build` 追加，2026-09-04。实现方：Claude Code。）

**顺序**：桩 → 测试（先跑红）→ `singbox.sh` → `update.test.sh` → 跑绿 → 文档。

| # | 文件 | 落地情况 |
|---|---|---|
| 1 | `tests/fixtures/bin/{dig,host,dscacheutil,ping,netstat,curl}` | 6 支桩。新增 `host` / `dscacheutil`；`dig` 加 `SB_FAKE_DIG_FAIL` / `SB_FAKE_DIG_IP`；`ping` 把调用次数写进状态目录（否则「重试 3 次」证不了）；`netstat` 加 `SB_FAKE_NO_GW`；`curl` 加 `SB_FAKE_IPINFO_FAIL` / `SB_FAKE_CN_FAIL` / `SB_FAKE_CN_IP` 与两个备胎 URL |
| 2 | `tests/verify.test.sh`（新增） | spec 表里的 1–12 条，每条验退出码 |
| 3 | `singbox.sh:95-108` | `VERIFY_POLICY_BAD` / `vpbad()`，注释写清两档的判据是「回滚换不换得回来」 |
| 4 | `singbox.sh` 新 helper | `_sb_resolve_a`（4 级降级）、`_sb_quic_open`（QUIC VN 探测）、`_sb_fetch_cn_ip`（三家参照站，输出 `<ip>|<归属>`） |
| 5 | `singbox.sh` `cmd_verify` | 五步判定重写，末尾 `1` / `2` / `0` 三档 |
| 6 | `singbox.sh` `_sb_verify_rounds` | 改读退出码；`2` 打 warn 后返回 0 |
| 7 | `singbox.sh` 帮助文本 | `verify` 与 `update` 两处补退出码语义 |
| 8 | `tests/update.test.sh` | setup 钉死 `SB_FAKE_QUIC=blocked`；新增第 13 条「仅策略档失败不回滚」 |
| 9 | `docs/safe-update.md` `docs/script-usage.md` `docs/best-practices.md` `README.md` | 同步 |

**与 spec 的三处偏离（实现时拍的）**

1. **多了一个测试后门 `SB_FAKE_PY_RESOLVE_FAIL=1`。** 降级链第 4 级是内联 `python3
   socket.getaddrinfo`，PATH 桩拦不住；联网机器上它总会成功，spec 的断言 4「四级全废」
   会永远假绿。这个后门只作用于第 4 级，1–3 级仍由真实 PATH 桩驱动。
2. **断言 13/14 落在 `tests/update.test.sh`**，不在 `verify.test.sh`——前者的现网监听 +
   tar 包 setup 有 60 行，复制一份得不偿失。
3. **断言 14（链路档失败 → 回滚）已被 `update.test.sh` 原有的第 6 条覆盖**
   （`SB_FAKE_VERIFY_FAIL=all`），只新增了 13。同时给 `update.test.sh` 的 setup 补
   `SB_FAKE_QUIC=blocked`——不钉的话原有 8 条用例的阶段 3 会去发真 UDP 包。
4. **`cmd_rollback` 的行为跟着变了，spec 的「受影响的接口」没列它。** 它与阶段 3 共用
   `_sb_verify_rounds`（`singbox.sh:1903`），所以回滚之后若只剩策略档失败，`rollback`
   的退出码从 `1` 变成 `0`、并打印「回滚完成，功能验收通过」。这与分档原则自洽——都已经
   换回旧内核了，DNS/QUIC/国内直连仍不对，只能说明问题本来就不在内核版本上——所以按
   现状保留，在此补一句申报。

**评审（`/sdlc-kit:review`）查出并已修的一处**

第 2 步的重试跳出条件原先写的是「响应体非空」（`[ -n "$soc_json" ]`），而硬失败的判据是
**解析出来的** `ip_soc` 为空。限流页 / 502 / Cloudflare 拦截页都是「非空但不是 JSON」且
`curl -s` 退 0——于是只请求 1 次就落到 `vpbad`，还打一句「连取 3 次都没结果」的假话，
一次抖动就把本该 `0` 的 verify 判成 `2`。改为在循环内解析、`[ -n "$ip_soc" ]` 才跳出，
并加了 `verify.test.sh` 第 13 条（`SB_FAKE_IPINFO_JUNK=1` → 退出 2 且 `ipinfo_calls` 为 3）
钉住它：旧写法下这条红（`通过 12，失败 1`），修完绿（`通过 13，失败 0`）。

**验证结果**（`./singbox-selfcheck.sh && ./tests/run.sh`）

- 写完测试、未改实现时：`通过 3，失败 9`，失败点名的是退出码（如「期望 2 实际 0」），不是语法错。
- 实现之后：静态自检 12 项全过；`selfcheck.test.sh` 26/26、`update.test.sh` 18/18、
  `verify.test.sh` 13/13（评审后从 12 条增到 13 条），退出码 `0`。

**真机那段仍待人工执行**（`./singbox.sh verify; echo "exit=$?"`），脚本已 deny。
