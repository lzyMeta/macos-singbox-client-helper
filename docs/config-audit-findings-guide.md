---
kind: spec
status: shipped
covers:
  - docs/config-audit-findings.md
  - tests/docs.test.sh
  - tests/config-audit.test.sh
---
# `config audit` 结论解读手册：每条「怎么办」背后的问题、实例与判断方法

## 问题

`config audit` 的报告只有一张汇总表加编号详情。「怎么办」一列是十几个字的短语，详情区只给
sagernet 官方迁移页的链接。这对 `--apply` 能自动改的 3 条够用，对其余 19 条「只报不改」的条目
不够——尤其是 2 条 `notice`，它们要求**人来判断**要不要改，报告却没给判断依据。

2026-09-12 真机还原（配置与 `config/config.example.json` 逐键相同）：

```
$ singbox config audit
#  结论  在哪                       谁发现的  怎么办
1  提示  dns.rules[0]               表        确认内部解析也受它影响是想要的
2  提示  dns.rules[1] dns.rules[2]  表        --deep 定性；是的话改 evaluate + match_response（2 处）

$ singbox config audit --deep
#  结论  在哪          谁发现的  怎么办
1  提示  dns.rules[0]  表        确认内部解析也受它影响是想要的
```

两处看不懂：

1. **第 2 条为什么 `--deep` 后消失了。** 脚本内部确实做了定性（沙箱建链成功、内核没打
   `Legacy Address Filter Fields` 这条 WARN → 规则集不含 IP 条目 → 撤掉），但报告一个字都不说，
   用户只能对比两次输出来猜「大概是没事了」。
2. **第 1 条「内部解析」是什么、「受它影响」指什么、「确认」要怎么做。** 表条目的 `note` 字段
   里有答案的一半（`1.14.0 起 query_type / ip_version 也作用于内部解析（resolve 动作、direct 出站的
   ICMP、endpoint 自身地址…）`），但 `note` 不打印；另一半——「在我这份配置里到底有没有影响」——
   哪里都没写。

不做的后果：`notice` 档的设计意图是「配置合法，但行为变了，人要确认」。确认不了，用户要么忽略
（等于这一档白报），要么照着官方英文迁移页硬改一份本来不需要改的配置。

## 决定

新增一份用户文档 `docs/config-audit-findings.md`（`kind: design`，与 `best-practices.md` 同级，
是要时刻准确、被测试守着的文档，不是设计记录），迁移表里**每个 `fix` 不是 `auto` 的条目一节**
（19 条：17 条 `deprecated` + 2 条 `notice`），节标题就是条目 `id`（GitHub 锚点即 `#<id>`），
每节固定四段：**问题是什么 → 拿 `config/config.example.json` 举例 → 怎么判断要不要改 → 改成什么样**。
报告端做三处小改：详情区每条多一行 `解读：<GitHub blob URL>#<id>`；`--deep` 撤掉离线 `notice` 时
打一行撤条说明；`legacy_address_filter_rs` 的「怎么办」短语改成不跑 `--deep` 也能先自判的写法。
`tests/docs.test.sh` 新增一项把文档与迁移表机械钉死。

### 文档结构

```
docs/config-audit-findings.md
# config audit 结论解读
## 怎么读这份文档               ← 报告三档（起不来/将来会坏/提示）各自意味着什么；「谁发现的」四种来源；
                                  --deep 与离线的差别；「--deep 后消失 = 已定性为不需要改」
## 只报不改的 19 条              ← 每条一节，标题为 `### <id>`，下一行加粗写报告里的「怎么办」原话
### query_type_ip_version_semantics
**报告原话：确认内部解析也受它影响是想要的**
问题是什么 / 模板里的例子 / 怎么判断 / 改成什么样
### legacy_address_filter_rs
...
```

每节四段的写法要求：

- **问题是什么**：一段话，说清 1.14.0 前后行为差在哪、哪个版本移除（`removed_in: None` 的写「不移除，
  只是行为变了」）。不复述官方页，给官方页链接。
- **模板里的例子**：贴 `config/config.example.json` 命中的那段 JSON（模板与 live 逐键全等，
  `template.test.sh` 在守，所以拿模板举例就是拿用户的真机举例，又不会把订阅地址写进仓库）。
  模板没命中的条目（`wireguard_outbound`、`hysteria_v1_tuning`、`inline_acme`、`legacy_dns_servers`
  等）用官方迁移页的最小片段，并**明写「模板未命中，以下是官方页的例子」**。
- **怎么判断**：可操作的判据，最好是一条命令或一个「看配置里 X 字段」的动作。禁止只写「视情况而定」。
- **改成什么样**：`fix: snippet` 的条目直接引用报告详情区已生成的建议写法；`fix: report` 的写
  改前/改后两段 JSON。

### 两条 `notice` 的正文（本规格先把它们写定，其余 17 条由 build 按同一模板补）

**`query_type_ip_version_semantics`**

- 问题：1.14.0 之前，`dns.rules` 里的 `query_type` / `ip_version` 只匹配**应用发来的** DNS 查询。
  1.14.0 起它们也匹配 sing-box **自己发起的**解析——「内部解析」指的就是这一类：路由动作
  `resolve` 把域名换成 IP 时的查询、`direct` 出站为 ICMP 做的解析、endpoint 自身地址的解析、
  给出站服务器域名做的 `domain_resolver` 查询。不移除，只是范围变大。另外这类规则不能与遗留地址过滤 /
  `strategy` / `rule_set_ip_cidr_accept_empty` 共存于同一份 DNS 配置。
- 模板例子：`dns.rules[0]` 是 `{"query_type": ["AAAA","HTTPS"], "action": "predefined", "rcode": "NOERROR"}`
  ——所有 AAAA / HTTPS 查询回空答案。1.14.0 起，内核自己查出站服务器地址、`resolve` 动作查目标域名时，
  AAAA 也一律拿到空答案，即**内核自己永远拿不到任何 IPv6 地址**。
- 怎么判断：看 `dns.strategy` 与各出站的 `domain_resolver.strategy`。模板是 `"strategy": "ipv4_only"`
  ——内核本来就只用 IPv4，AAAA 回空对它零影响，**这条提示对模板/真机配置是「想要的」，不用改**。
  什么时候要改：`strategy` 是 `prefer_ipv6` / `ipv6_only`，或某个出站服务器只有 AAAA 记录（纯 IPv6 VPS），
  或有 `resolve` 动作且后面的路由规则依赖 IPv6 `ip_cidr`。
- 改成什么样：把这条规则限定到应用查询——给它加 `"inbound": ["tun-in"]`（只匹配从 TUN 进来的查询，
  内部解析没有 inbound，不命中）；或者删掉它、改用 `strategy` 控制。文档里给出改后 JSON。

**`legacy_address_filter_rs`**

- 问题：1.14.0 把 DNS 规则里按**响应 IP** 过滤（`ip_cidr` / `ip_is_private` / `ip_accept_any`）的写法
  废弃，1.16.0 移除，改成 `action: route-options` + `evaluate` 取响应再 `match_response` 匹配。
  DNS 规则引用规则集时，如果规则集里有 `ip_cidr` 条目（典型是 `geoip-*`），内核就把它当成这种
  废弃用法。离线审只看得到规则集**名字**，看不到内容，所以只能报 `notice`。
- 模板例子：`dns.rules[1]` 引用 `geosite-category-ads-all`，`dns.rules[2]` 引用
  `geosite-cn` / `geosite-apple-cn` / `geosite-microsoft-cn`。四个都是 `geosite-*`，纯域名规则集，
  不含任何 IP 条目。
- 怎么判断：先看名字——`geosite-*` 是域名集，`geoip-*` 是 IP 集，前者可忽略、后者就是废弃用法；
  名字看不出来（自建规则集）就跑 `singbox config audit --deep`：沙箱真跑一次内核，规则集含 IP 条目
  内核会打 WARN，这条升为「将来会坏」；不含，这条撤掉并打一行撤条说明。**`--deep` 后这条消失 =
  已定性为不是废弃用法，不用改。** 模板/真机就是这种情况。
- 改成什么样：确实是 `geoip-*` 时，把 `rule_set` 从该条 DNS 规则里拆出去，改成两条——先
  `{"action": "route-options", ... "evaluate": true}` 之类取响应，再 `{"match_response": true, "rule_set": "geoip-xx", ...}`
  匹配；具体片段引用官方页 `#migrate-address-filter-fields-to-response-matching`，build 时对着
  v1.14.0 的 `docs/migration.md` 核一遍再写。

### 报告端的三处改动

1. **详情区每条加一行解读链接**。在 `desc` / `url` 之后加
   `    解读：https://github.com/lzyMeta/macos-singbox-client-helper/blob/main/docs/config-audit-findings.md#<id>`。
   只有 `fix != auto` 的条目有这一行（文档只写这 19 条）；A/B 路的表外发现（`unknown field`、
   schema 未知键、表外 WARN）没有 `id`，不加。URL 前缀放一个常量（如 `DOC_FINDINGS_URL`），
   不要在 python 段里拼字面量——`docs.test.sh` 要从这里抓值核对。
2. **`--deep` 撤条说明**。`singbox.sh` 里 `rows = [r for r in rows if not (...)]` 那一步，把撤掉的
   路径收起来，报告末尾（表格之后、退出码统计之前）打一行：
   `--deep 已排除 1 条：dns.rules[1] dns.rules[2] 引用的规则集经沙箱确认不含 IP 条目，不是废弃的地址过滤用法`。
   撤了 0 条不打。这行文案要出现在 `tests/config-audit.test.sh:785-799` 那个已有的反向定性用例里作为断言。
3. **短语改写**。`legacy_address_filter_rs` 的 `action` 从 `--deep 定性；是的话改 evaluate + match_response`
   改为 `规则集是 geoip/IP 类才算；纯域名（geosite-*）可忽略，拿不准用 --deep 定性`。其余 18 条短语不动。
   `tests/config-audit.test.sh` 里以 `row` / `inlog` 钉住旧短语的断言跟着改。

### 机械同步（`tests/docs.test.sh` 新增一项）

- 从 `singbox.sh` 的 `TABLE` 抓出所有 `fix` 不为 `auto` 的 `id`（复用 T13 抓 `sagernet.org/migration/#` 锚点的
  `grep -o` 思路，别 `source` 脚本）；每个 `id` 在 `docs/config-audit-findings.md` 里必须有且只有一个
  `^### <id>$` 标题。
- 反向：文档里每个 `### ` 标题都必须是表里现存的 `id`——防止删了条目文档还留着一节。
- `DOC_FINDINGS_URL` 常量里的文件名必须与 `docs/` 下实际文件名一致。
- 每节四段的小标题（「问题是什么 / 模板里的例子 / 怎么判断 / 改成什么样」）每节都要齐——防止
  写到后面偷懒只剩链接。

## 不在范围内

- **不改 `--apply`**：3 条 `fix: auto` 的条目不写进文档，也不新增任何自动改写规则。
  「改成什么样」是给人看的，不是给脚本执行的。
- **不把文档装到本机**：`install` 仍只装 `singbox.sh` 到 `/usr/local/bin/singbox`，解读一律走 GitHub URL。
  离线看不到解读是接受的代价。
- **不解析规则集内容**：离线 `notice` 的定性仍只靠 `--deep` 沙箱日志与规则集名字前缀，不下载
  `.srs` 文件做本地判断。
- **不改表格列**：五列不变，不加「id」列。`id` 只在详情区的解读 URL 里出现。
- **不改 A/B 路表外发现的文案**：`unknown field`、schema 未知键、表外 WARN 三类没有 `id`，不进文档。
- **不翻译或镜像官方迁移页**：每节只写「对本仓库模板配置意味着什么」，官方页的完整语义仍以链接为准。
- **不动 `manual-config.md` 的结构**：它是 `kind: manual`（≤ 120 行、四个固定 H2），只在「深入阅读」
  加一条链接。

## 受影响的文件与接口

| 文件 | 改动 |
|---|---|
| `docs/config-audit-findings.md` | **新建**。`kind: design`；「怎么读」+ 19 节；每节 `### <id>` + 四段 |
| `singbox.sh` | `_cfg_audit_report` 详情区加「解读」行（仅 `fix != auto`）；新增 `DOC_FINDINGS_URL` 常量；`--deep` 撤条处收集路径并在报告末尾打一行；`legacy_address_filter_rs` 的 `action` 短语改写；`VERSION` 不在本规格里推 |
| `tests/config-audit.test.sh` | 反向定性用例加撤条文案断言；钉旧短语的断言改新短语；新增一例：`--config config/config.example.json` 的详情区含 `解读：…#query_type_ip_version_semantics` |
| `tests/docs.test.sh` | 新增一项：19 个 `id` ↔ 文档 `### ` 标题双向一致、四段小标题齐全、URL 文件名与实际文件一致 |
| `README.md` | 第 4 节文档索引加一行；第 5 节仓库结构树加一行（`docs.test.sh` 第 3/4 项会红着等你） |
| `docs/manual-config.md` | 「深入阅读」加链接；第 3 步那句「只看『结论』与『怎么办』两列」后补半句「看不懂的按详情区『解读』链接」 |
| `docs/maintaining.md` | 「迁移表怎么维护」一节加一步：往 `TABLE` 加 `fix != auto` 的条目时，必须同时在 findings 文档加一节，`docs.test.sh` 守着 |
| `CLAUDE.md` | 验收段里 `docs` 测试的描述加上「findings 文档与迁移表双向一致」 |

不涉及跨栈契约。`.claude/sdlc.json` 不改。

## 待定问题

- **`kind: design` 能否有第二份**：`sdlc-doc lint` 的 D 规则对 `design` 有没有「仅一份」之类限制，
  build 第一步跑 `sdlc-doc lint` 验证；不行就换 `kind: manual` 之外的其他合法值，绝不能是 `manual`
  （会撞 D4 的 120 行上限）。责任人：build。
- **`legacy_address_filter_rs` 的「改成什么样」片段**：`route-options` + `evaluate` + `match_response`
  的确切写法要对着 v1.14.0 tag 的 `docs/migration.md` 核，不要凭记忆。责任人：build（用 `sdlc-docs`，
  库 `/sagernet/sing-box` 1.14.0 已在 `docs.context7.libraries`）。
- **`query_type_ip_version_semantics` 改法里 `inbound` 字段是否真能排除内部解析**：内部解析的
  DNS 查询上下文没有 inbound tag 是源码层面的推断（`dns/router.go` 的 `adapter.InboundContext`），
  build 时用 `--deep` 沙箱或直接读 v1.14.0 源码确认；确认不了就把「改成什么样」写成
  「删掉本条、改用 `strategy`」这一种。责任人：build。
- **模板未命中的条目例子来源**：官方迁移页片段是否有版权顾虑——是 MIT/GPL 文档，引用附链接即可，
  build 时统一在文档开头注一句出处。责任人：build。

## 验证

```bash
./singbox-selfcheck.sh && ./tests/run.sh          # 全绿，含 docs.test.sh 新增项与 config-audit.test.sh 改过的断言
sdlc-doc lint                                      # 新文档 kind/covers 合法，README 索引不失联

# 报告端三处改动的直接观察（不需要 root，审模板）
./singbox.sh config audit --config config/config.example.json | grep -c '解读：https://github.com/lzyMeta/macos-singbox-client-helper/blob/main/docs/config-audit-findings.md#'
# 期望 ≥ 2（query_type_ip_version_semantics 与 legacy_address_filter_rs 各一行）
./singbox.sh config audit --config config/config.example.json | grep -F 'geosite-*'
# 期望命中新短语「规则集是 geoip/IP 类才算；纯域名（geosite-*）可忽略，拿不准用 --deep 定性」

# 文档与表双向一致（docs.test.sh 新项的手工等价）
ids=$(grep -o '{"id": "[a-z0-9_]*", "action"' singbox.sh | sed 's/.*"id": "\([^"]*\)".*/\1/')
for id in $ids; do grep -q "^### $id\$" docs/config-audit-findings.md && echo "有 $id"; done | wc -l   # 期望 19
grep -c '^### ' docs/config-audit-findings.md                                                        # 期望 19
```

`--deep` 撤条说明那行走 `tests/config-audit.test.sh` 的假沙箱日志用例（`SB_FAKE_RUN_LOG` 去掉
`Address Filter` 行后 `audit --deep`），断言 `inlog '--deep 已排除 1 条'`；真机 `--deep` 要网络，
人自己跑一次对照即可。

## 实现计划

2026-09-12 build 落地，顺序与证据：

1. `tests/docs.test.sh` 第 9 项（表 ↔ 文档双向、四段齐全、`DOC_FINDINGS_URL` 文件名）——先跑：红，
   点名 `docs/config-audit-findings.md 不存在——迁移表里 19 条只报不改的条目没有解读`。
2. `tests/config-audit.test.sh`：T7b 反向定性用例加 `--deep 已排除 1 条` 断言与「离线不打」反例；新增 T14
   （模板配置两条 notice 的解读行、新短语、auto 条目无解读行）——先跑：退 1，4 条 FAIL 各自点名。
3. `singbox.sh`：`DOC_FINDINGS_URL` 常量；`_cfg_audit` TSV 加第 8 列 `doc_id`（`fix != auto` 才填）；`--deep`
   撤条处收集路径、以 `tier=dropped` 行传给报告端；`_cfg_audit_report` 表格后打撤条行、详情区 `url` 后打
   `解读：` 行；`legacy_address_filter_rs` 短语改写；两处挂载点跳过 `dropped`。再跑：`config-audit` 122/0、`docs` 12/0。
4. `docs/config-audit-findings.md`：导读 + 19 节。两条 notice 按本规格写，其余 17 条的例子取自 v1.14.0 tag
   的 `docs/migration.md` / `deprecated.md` / `changelog.md`。
5. README 索引与结构树、`manual-config.md`（第 3 步半句 + 深入阅读）、`maintaining.md` 第 6 步、`CLAUDE.md`
   验收段。`sdlc-check` 全绿（`main` 退 0、`doc` 退 0）。

待定问题的答案：

- `kind: design` 可以有第二份，`sdlc-doc lint` 通过。`covers` 写 `singbox.sh` + `config/config.example.json`——
  迁移表或模板一变，`sdlc-doc stale` 就点名它。
- `legacy_address_filter_rs` 改法：官方是 `"action": "evaluate"` 取响应 + 下一条 `"match_response": true`，
  **不是**本规格猜的 `route-options` + `evaluate: true`；文档按官方片段写。
- **`inbound` 排除不了内部解析**：`route/conn.go` 的 `adapter.WithContext(ctx, &metadata)` 把连接的入站上下文带进了
  `resolve` / direct 出站触发的解析。文档「改成什么样」只写「删掉本条、改用 `strategy`」与「给出站配 `domain_resolver`
  绕开 DNS 规则」两条。另一个更准的判据来自官方迁移页：指定了服务器的解析（`domain_resolver` /
  `default_domain_resolver` / 带 `server` 的动作）**不过 DNS 规则**——模板全配了，所以这条提示对模板实际无影响。
- 官方片段出处在文档开头注明（GPL-3.0-or-later，引用附链接）。
- **`DOC_FINDINGS_URL` 钉在 `blob/v${VERSION}` 而不是 `blob/main`**（2026-09-12 打 tag 前改）：装在本机的
  脚本与它的迁移表是同一提交，链接指向同一提交的文档快照，`main` 往前走、某条 `id` 撤了也不会断旧脚本的链接。
  代价是 tag 推上去之前链接 404，开发期看本地 md。测试按脚本自己的 `VERSION` / `SELF_REPO` 展开后核对。
