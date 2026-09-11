# `config audit` 数据源扩展：内置迁移表与沙箱日志档

## 问题

上一轮（`docs/config-audit-and-modernize.md`）落地的 `config audit` 只有两路发现层：内核 `check`
的输出和内核 `schema` 的结构比对。真机上它抓到了 21 处 `download_detour`，然后报「干净」——
但 1.14.0 的弃用清单有 8 条，它对其中大半是盲的。2026-09-10 用真内核逐条实测（fixture 在
`scratchpad/probe/`，全部只读、不碰 live）：

| 1.14.0 弃用项 | `check` | `schema` | `run` |
|---|---|---|---|
| `download_detour` | 沉默 | ✓ 未知键 | WARN |
| 隐式默认 HTTP client | 沉默 | **看不见**（不是键，是「没写键」） | WARN |
| `tls.acme` | WARN | ✓ | WARN |
| DNS 规则动作 `strategy` | 沉默 | ✓ | WARN |
| `rule_set_ip_cidr_accept_empty` | WARN | ✓ | WARN |
| `independent_cache` | WARN | ✓ | WARN |
| `store_rdrc` | WARN | ✓ | WARN |
| 不带 `match_response` 的 `ip_cidr` / `ip_is_private` | 沉默 | **看不见**（键合法，用法废弃） | WARN |
| Hysteria v1 调优字段（changelog 才有，deprecated 页没列） | 沉默 | ✓ | **沉默** |

两个结构性盲区：**「键合法但用法废弃」**的两条，`check` 与 `schema` 都无能为力；`run`
虽然全报，但 WARN 是在 `dns.Router.Start`（`dns/router.go:156-161`）和规则集
`resolveTransport`（`route/rule/rule_set_remote.go:311`）里打的——远程规则集下不到时进程
在 `initialize rule-set` 就死了，DNS 那几条 WARN 根本走不到（实测 `combo_nonet.json`：只有
隐式 HTTP client 一条 WARN，地址过滤与 strategy 两条没出现）。所以 `run` 档**依赖网络**。

另外三个数据源层面的事实，决定了这次不能只「再多抓几个字段」：

1. **网站是活的，内核是死的。** `https://sing-box.sagernet.org/changelog/` 现在最上面是
   1.15.0-alpha.2；审查的对象却是本机装的 1.14.0。三个页面在源码仓库里就是
   `docs/deprecated.md` / `docs/migration.md` / `docs/changelog.md`，按 git tag 取才对得上内核。
2. **文档与内核互有遗漏，且两个方向都有。** 内核 WARN 给的 `strategy` 迁移链接
   `#migrate-dns-rule-action-strategy-to-rule-items` 在 v1.14.0 的 `docs/migration.md` 里
   **不存在**（死链）；deprecated 页漏了 Hysteria v1 调优字段（源码 `option/hysteria.go:17-51`
   标 `schema:"omit"`，但 `experimental/deprecated/constants.go` 里没有对应 Note，内核永远不
   告警）和 `tun.endpoint_independent_nat`（`option/tun.go:71` 注释 `Deprecated: removed`，
   `docs/configuration/inbound/tun.md:551` 仍当有效字段讲）。反方向：deprecated 页说 `block`
   出站 1.13.0 已移除，实测 1.14.0 的 `check` 与 `run` 都放行，schema 的 outbound `type` 枚举里
   `block` 还在。
3. **概括性文字复现不出正确的改写。** 地址过滤字段的文档只说「Only takes effect for
   address requests」，读成「非地址查询时过滤不生效但规则仍命中」是自然的——而源码
   `dns/router.go:296` 是 `if currentRule.WithAddressLimit() && !isAddressQuery { continue }`：
   **整条规则跳过**。按文档写出的等价形式会多出一条永远不该有的兜底。语义只能从源码取。

## 决定

发现层从两路扩到**四路**，改写层从 1 条规则扩到 **3 条纯键名规则**，报告加一档不影响退出码的
`notice`。所有数据源**以本机内核版本对应的 git tag 为准**，网站只做人工核对。

### 四路发现层

| 路 | 抓什么 | 代价 | 新旧 |
|---|---|---|---|
| A `check` | 内核在 `New()` 阶段上报的 WARN / FATAL（自带官方链接） | 毫秒、离线 | 已有 |
| B `schema` | 源码里 `schema:"omit"` 的全部字段 —— 即「未知键」 | 毫秒、离线 | 已有 |
| C **迁移表** | 内置于 `singbox.sh` 的一张表，每条是一个 JSON 路径谓词。能表达 A/B 表达不了的**用法条件**：「远程规则集既无 `http_client` 也无 `download_detour`，且 `route.default_http_client` 与 `http_clients` 都空」（隐式 HTTP client 的精确判定，`common/httpclient/manager.go:41-44,76-80`）、「DNS 规则有 `ip_cidr`/`ip_is_private`/`ip_accept_any` 且 `match_response` 未开」（`dns/router.go:1383-1386`） | 毫秒、离线；**要人维护** | 新增 |
| D **沙箱 run 日志** | 内核 `Start()` 阶段上报的 WARN（`grep 'deprecated in sing-box'`），版本无关，表里没收录的新条目也抓得到 | 分钟级、**要网络**（冷 cache 要下全部远程规则集） | 新增 |

裸跑 `config audit` = A + B + C，仍是毫秒级离线。`--deep` 加 D（把上一轮预留给
「`/rules` 语义 diff」的 flag 位挪作此用，那个用途已随上一轮「不在范围内」第 1 条一起放弃）。
D **不额外起沙箱**：凡是已经在跑沙箱的地方（`cmd_update` 阶段 1、`--apply` 第 3 道）顺手收割
日志，`--deep` 只是让裸审查也起一次。无网络时 D 降级并在输出里明说，与第 3 道现有的 3/4 降级
同一口径。

同一条发现可能被多路抓到（`store_rdrc` 四路全中），**按路径去重**，来源栏列出所有命中的路
（`check+schema+table`），这样报告本身就是覆盖矩阵的真机证据。

### 迁移表的条目与来源

表的每条：`id`、谓词、`deprecated_in`、`removed_in`、`tier`、经核对的迁移链接、说明、
`fix`（`auto` / `snippet` / `report`）。**表头记 `covers=1.14.0`**：内核 minor 高于它时打一行
「迁移表只覆盖到 1.14.0，内核 X 新增的废弃项请用 `--deep` 或查 <deprecated 页>」，退出码不受
影响。

条目从四处整理，全部钉在 **sing-box `v1.14.0` tag**：

- `docs/deprecated.md`、`docs/migration.md`、`docs/changelog.md`（三页的源）
- `experimental/deprecated/constants.go`（内核真正会告警的 11 条 Note，含 1.12 排期到 1.14 的 3 条）
- `option/*.go` 里 `schema:"omit"` 的字段（B 路的精确定义，共 50 处）
- 上报点位置（`deprecated.Report` 的 15 处调用），用来标每条是 `New()` 阶段（A 能抓）还是
  `Start()` 阶段（只有 D 能抓）

1.14.0 一节的条目与裁定：

| id | 谓词 | A | B | C | D | fix |
|---|---|---|---|---|---|---|
| `download_detour` | `route.rule_set[type=remote].download_detour` | – | ✓ | ✓ | ✓ | **auto**（已有） |
| `independent_cache` | `dns.independent_cache` 存在 | ✓ | ✓ | ✓ | ✓ | **auto**：删键（migration 原话「Simply remove the field」） |
| `store_rdrc` | `experimental.cache_file.store_rdrc` 存在 | ✓ | ✓ | ✓ | ✓ | **auto**：值为 true 且无 `store_dns` → 改名为 `store_dns: true`；否则删键 |
| `implicit_http_client` | 见上表 C 列 | – | – | ✓ | ✓ | report（⑥ 型全局副作用，上一轮已排除） |
| `inline_acme` | `inbounds[].tls.acme` | ✓ | ✓ | ✓ | ✓ | report（服务端 TLS，客户端项目零命中） |
| `dns_rule_strategy` | `dns.rules[**].strategy`（含 logical 子规则与 `route-options` 动作） | – | ✓ | ✓ | ✓ | **snippet**：`ipv4_only` / `ipv6_only` 给等价片段；`prefer_*` 无等价；链接指向 DNS rule action 页的 `strategy` 小节并注明「v1.14.0 无 migration 章节，内核链接为死链」 |
| `accept_empty` | `dns.rules[**].rule_set_ip_cidr_accept_empty` | ✓ | ✓ | ✓ | ✓ | report |
| `legacy_address_filter` | `dns.rules[**]` 有 `ip_cidr`/`ip_is_private`/`ip_accept_any` 且 `match_response` 未开 | – | – | ✓ | ✓ | **snippet** |
| `legacy_address_filter_rs` | `dns.rules[**]` 引用 `rule_set` 且 `match_response` 未开 | – | – | ✓（**notice**） | ✓（升为 deprecated） | report。离线不知道规则集里有没有 `ip_cidr` 条目（`dns/router.go:1631-1638` 靠规则集元数据判），表只能报 notice「若该规则集含 ip_cidr 则为废弃用法，用 `--deep` 定性」 |
| `hysteria_v1_tuning` | `outbounds[type=hysteria]` / `inbounds[type=hysteria]` 的 `recv_window_conn` / `recv_window` / `recv_window_client` / `max_conn_client` / `disable_mtu_discovery` | – | ✓ | ✓ | – | report，说明「内核不会告警，deprecated 页未列，见 changelog 1.14.0 注 23」 |
| `tun_removed_fields` | `inbounds[type=tun].endpoint_independent_nat` / `.gso` | – | ✓ | ✓ | – | report，说明「源码标 removed、静默忽略；tun 文档仍列为有效」 |

1.12 排期到 1.14、内核 1.14.0 仍在 `Start()` 阶段告警的 3 条也进表（`outbound` DNS 规则项、
出站 `domain_strategy`、缺 `domain_resolver`），前两条 B 能抓，第三条是用法条件，只有 C/D。
1.10–1.13 已被内核拒绝的（`inet4_address`、legacy inbound fields、旧 DNS 服务器格式…）进表只为
给链接和解释——它们的 `removed` 定性来自 A 的 FATAL，不来自表。

### 分档规则（承上一轮的三档，加一档）

| 档 | 谁能给 | 退出码 |
|---|---|---|
| `removed` | **只有 A**（`unknown field` 或 FATAL） | 1 |
| `deprecated` | A 的 WARN、B 的未知键、C 的谓词命中、D 的 WARN | 2 |
| `notice` | 只有 C 的行为变更条目 | **不影响** |

表里 `removed_in ≤ 内核版本` 但 A 沉默的条目（`block` 出站那种），报 `deprecated` 并附一句
「文档称已在 X 移除，本内核仍接受」。**表自己永远不产生 `removed`**——内核会不会拒，只有
内核说了算。

`notice` 条目（1.14.0）：

- `dns.rules[**]` 用了 `query_type` 或 `ip_version` → 「1.14.0 起也作用于内部解析」，链接
  `migration/#ip_version-and-query_type-behavior-changes-in-dns-rules`。样例配置 `dns.rules[0]`
  命中。
- 规则集合并匹配语义纠正（changelog 注 14）：**只在 `cmd_update` 挂载点、旧版本 < 1.14.0 ≤ 新版本
  时打一次**，裸审查不打——它没有可离线判定的谓词，每次都打就是噪音。

`$schema` 顶层字段（实测 `check` 接受，`option/options.go:17`）**不进 audit**，只写进
`config/config.example.json` 与 `docs/best-practices.md`：它是给手写配置的人用的编辑器补全，
符合项目理念，但「建议引入 X」是策略不是合法性。其余 1.14 新功能一律不引入，理由见
「不在范围内」。

### 改写层：3 条纯键名规则

边界：**官方 `docs/migration.md` 有完整前后 JSON 对照，且语义无分支**。三条都满足；
`_cfg_migrate` 与 `_cfg_whitelist_diff` 改为**共用一张规则表**（路径、旧键、新键、值映射），
不再各自硬编码 `download_detour`。四道验收原样通用：白名单 diff 只许落在规则表列出的路径上、
值逐字（`store_rdrc → store_dns` 的值映射是恒等）、`check` 过、沙箱起得来、发现层归零。

`--apply` 的确认提示要**逐条列出将改哪些键、各几处**——三条规则同时命中时，人要看得出
改了什么。

`snippet` 型条目不落地，报告里打「建议写法（按 v1.14.0 源码语义推导，未经行为验证，
需人工核对）」。片段的语义依据：

- **地址过滤**（`dns/router.go:294-298, 1120-1176, 1338-1346`）：遗留 = 非 A/AAAA/HTTPS
  查询**整条跳过**；地址查询用**本条的 server** 查，响应不匹配则从下一条继续。等价新形式是
  两条，且两条都要限定 `query_type`：

  ```json
  {"<原匹配条件>", "query_type": ["A","AAAA","HTTPS"], "action": "evaluate", "server": "<原 server>", "tag": "mig-af-N"}
  {"<原匹配条件>", "query_type": ["A","AAAA","HTTPS"], "match_response": "mig-af-N", "<原地址过滤字段>", "action": "respond"}
  ```

  不照官方示例（用 remote evaluate 再 route 到 local）：那换了决定服务器，不是等价改写。
  原规则若带 `rewrite_ttl` / `disable_cache` / `client_subnet`，搬到 evaluate 那条。
- **`strategy`**（`dns/client.go:261-266, 616-630`；`dns/router.go:319-321`）：`ipv4_only` =
  AAAA 查询直接回空 NOERROR、HTTPS 应答剥掉 ipv6hint；`ipv6_only` 对称；`prefer_*` 只影响内部
  `Lookup` 的排序，对客户端查询无效果。所以 `ipv4_only` 的片段是在原规则前插一条
  `{"<原匹配条件>", "query_type": ["AAAA"], "action": "predefined", "rcode": "NOERROR"}`（HTTPS
  hint 剥离无等价，注明）；`prefer_*` 只报「删掉即可，客户端查询路径上它本来就没作用」。

### 其他四件

1. **死链与文档遗漏**：表里每条链接都是核对过 v1.14.0 `docs/` 后的；A/D 路从内核 WARN 抠出的
   链接若在表里有同 id 条目，**以表为准覆盖**。
2. **「文档称已移除、内核仍接受」**：见分档规则。
3. **`tests/run.sh` 连跑偶发 2 条红**：`LOCKDIR=/tmp/.singbox-sh.lock`（`singbox.sh:69`）写死，
   测试与 live 的 `singbox` 命令、以及测试之间共用一把锁；`acquire_lock` 等 3×2 秒就 `die`。
   改为 `LOCKDIR="${SB_LOCKDIR:-/tmp/.singbox-sh.lock}"`，`tests/run.sh` 给每个测试文件一个
   `mktemp -d` 下的锁目录。根因（残留锁的 PID 恰好是活着的测试进程、还是与 live 命令撞锁）
   在 build 阶段用 `SB_LOCKDIR` 隔离后复跑 10 次确认——隔离后仍红就说明不是锁的事，另立项。
4. **脚本 `networksetup` 切 DNS 与 1.14 `dns_mode` 的关系——定立场：保留，不引入 `dns_mode`。**
   依据：sing-box v1.14.0 依赖 sing-tun `v0.9.0-beta.4`，其 `tun_darwin.go` **没有任何设置
   接口 DNS 的代码**（只有 `tun_windows.go:84-109` 的 `luid.SetDNS` 与 Linux 的 nftables/
   iproute2 分支）；文档「per-interface DNS on Apple platforms」指的是图形客户端的
   NetworkExtension 路径。真机旁证：内核 1.14.0 运行中 Wi-Fi 的 DNS 仍是脚本设的 1.1.1.1，
   `scutil --dns` 没有 utun 作用域解析器。把这段依据写进 `docs/best-practices.md`，并留一句
   「sing-tun 在 darwin 上实现 DNS 设置的那天要重评」。

## 不在范围内

1. **结构性改写不自动落地。** 地址过滤、`strategy` 只出片段；`tls.acme`、隐式 HTTP client、
   Hysteria 调优只报。片段按源码推导，但没有行为差分验证（需要旧内核二进制，本机
   `$BIN.prev` 只在 `update` 后才有），所以不落地。
2. **不引入 1.14 的其余新功能**，逐条否决理由：`optimistic` / `store_dns` / `dns.timeout` 是
   DNS 策略，属 `best-practices.md` 而非合法性；`initial_path` 解决的是启动阻塞，live 有
   `cache.db` 不阻塞；多 tag 规则集 + `{tag}` 占位会把 21 条重排成几条，是配置重构不是适配；
   `http_clients` + `route.default_http_client` 是 ⑥ 型全局默认；API service / dashboard /
   `sing-box api` 与脚本用的 clash_api 并行存在，无替换必要；`udp_*` NAT、`preferred_by`、
   mDNS、TLS spoof、`bridge` 出站与 macOS 单机客户端场景无关。
3. **不在运行时抓网页。** 表是人维护的，源是 git tag；`config audit` 保持离线。
4. **不做 `/rules` 语义 diff。** `--deep` 的含义改为沙箱日志档，原预留用途作废。
5. **不解析 `cache.db` 去判断规则集内容。** `legacy_address_filter_rs` 的定性交给 D。
6. **不改 `_sb_derive_config` 的派生规则**（`clash_api` 仍 pop、inbound 仍换成 mixed）。派生件
   看不见的段落里的废弃项由 A/B/C 覆盖，D 只是补「用法废弃」那两条。
7. **不动 `dns_backup_save` / `dns_apply_proxy` 的行为**，只写立场。
8. **不为老内核（< 1.14.0）补表条目的兼容测试。** 版本闸门维持上一轮：低于 1.14.0 只用 A 路，
   `--apply` 直接 `die`。

## 受影响的文件与接口

### `singbox.sh`

| 改动 | 位置 |
|---|---|
| `LOCKDIR` 可由 `SB_LOCKDIR` 覆盖 | `singbox.sh:69` |
| 新增迁移表（heredoc 常量，内联 python 消费；`<<'PY'` 不展开） | `_cfg_audit` 附近，新函数 `_cfg_table` |
| `_cfg_audit` 加 C 路；加按路径去重与来源合并；加 `covers` 版本告警 | `singbox.sh:2060-2249` |
| `_cfg_audit` 加 D 路：接受一个沙箱日志路径参数；`--deep` 时自己起沙箱 | 同上；沙箱复用 `_sb_derive_config` / `_sb_health`（`2850-2949`） |
| `_cfg_audit_report` 加 `notice` 渲染，退出码不看它 | 现有函数 |
| `_cfg_migrate` / `_cfg_whitelist_diff` 改为共用规则表，3 条规则 | `singbox.sh:2282-2366` |
| `_cfg_apply` 确认提示逐条列规则与命中数；第 3 道沙箱日志喂给 D | `singbox.sh:2375-2472` |
| `cmd_update` 阶段 1 沙箱日志喂给 D；旧 < 1.14.0 ≤ 新时打规则集语义 notice | `singbox.sh:3090, 3141` |
| `--deep` 从「尚未实现」改为 D 路 | `config audit` 参数解析 |

**接口约定**（增量）：

```
singbox config audit [--config <path>] [--apply] [--deep]
```

- `--deep`：加沙箱日志档。无网络时降级并打 `warn`，退出码按 A/B/C 定。
- 发现行格式不变（`<tier>\t<source>\t<json路径>\t<说明>\t<链接>`），`tier` 增加 `notice`，
  `source` 允许 `+` 连接多路（`check+schema+table`）。
- 环境变量 `SB_LOCKDIR`：锁目录，默认不变。

### 测试

| 文件 | 改动 |
|---|---|
| `tests/run.sh` | 每个测试文件独立 `SB_LOCKDIR` |
| `tests/config-audit.test.sh` | 新增断言见「验证」 |
| `tests/fixtures/bad-implicit-http-client.json` | 新增：远程规则集无 `http_client` 无 `download_detour`，`http_clients` 空 |
| `tests/fixtures/good-explicit-http-clients.json` | 新增：同上但 `http_clients` 非空 —— 不许报（`manager.go:42-44`） |
| `tests/fixtures/bad-legacy-address-filter.json` | 新增：`ip_is_private` 无 `match_response`；另含一条带 `match_response: true` 的同类规则，不许报 |
| `tests/fixtures/bad-store-rdrc.json` / `bad-independent-cache.json` | 新增：各自的 `--apply` 样本，前者含一份已有 `store_dns` 的变体 |
| `tests/fixtures/bad-hysteria-tuning.json` | 新增：只有 B/C 能抓，D 必须沉默 |
| `tests/fixtures/notice-query-type.json` | 新增：只命中 notice，退 0 |
| `tests/fixtures/sandbox-run.log` | 新增：一份含 3 条 WARN 的假沙箱日志，D 路离线用 |
| `tests/fixtures/fake-sing-box` | `run` 子命令加 `SB_FAKE_RUN_LOG=<路径>` 后门，把指定日志吐到 stderr |
| `tests/fixtures/schema-min.json` | 补 `DNSRule` / `DNSRuleAction` / `CacheFileOptions` / `HysteriaOutbound` 的裁剪定义 |

### 文档与配置

| 文件 | 改动 |
|---|---|
| `config/config.example.json` | 顶层加 `"$schema"` |
| `docs/best-practices.md` | 加 `$schema` 一段；加「系统 DNS 切换与 `dns_mode`」立场一段（含 sing-tun 依据） |
| `docs/script-usage.md` | `config audit` 一节：四路、`notice`、`--deep`、`SB_LOCKDIR`；**加「迁移表怎么维护」小节**：内核出新 minor 时，按 `git tag` 读那四处源，更新表与 `covers`，网站只做核对 |
| `docs/config-audit-and-modernize.md` | 顶部加一行指向本文（`--deep` 语义变更、改写规则从 1 条到 3 条） |
| `README.md` | `config audit` 那行提 `--deep` |
| `CLAUDE.md` | 「八个测试文件」→ 九个；提 `SB_LOCKDIR` |

## 待定问题

1. **D 路在 `--deep` 下的沙箱等待时长。** 现有 `SANDBOX_WAIT=40` 是为 `--apply` 第 3 道定的；
   `--deep` 只要等到 `dns.Router.Start` 打完 WARN，理论上比建链短，但没有可靠的「打完了」信号。
   先沿用 40 秒 —— 责任人：实现者
2. **`legacy_address_filter_rs` 的 notice 会不会太吵。** 样例配置 `dns.rules[1-2]` 都引用规则集
   且无 `match_response`，裸审查每次都会打 2 条 notice。若真机上嫌吵，改为只在 `--deep` 无法
   定性时打 —— 责任人：lzyMeta（真机看过报告后定）
3. **`snippet` 片段要不要带 `tag`。** `mig-af-N` 的 N 取原规则下标；若配置里已有同名 tag
   （不太可能但可能），片段就撞了。片段不落地，所以撞了也只是人抄的时候要改 —— 责任人：实现者
4. **flaky 的根因**：见「其他四件」第 3 条，隔离后复跑 10 次仍红则另立项 —— 责任人：实现者
5. **`covers` 告警的阈值用 minor 还是完整版本。** 1.14.1 不该告警，1.15.0 该；用 minor 比较
   即可，但 `ver_gt`（`singbox.sh:827`）是三段比较，要么加个 minor 比较，要么表头写
   `covers=1.15.0`（表示「1.15.0 之前」）—— 责任人：实现者

## 验证

### 机械验收（离线）

```
./singbox-selfcheck.sh && ./tests/run.sh
```

`tests/config-audit.test.sh` 新增断言：

| # | 断言 |
|---|---|
| 1 | `bad-implicit-http-client.json` 退 2，点名 `route.rule_set[0]`，来源含 `table`；`good-explicit-http-clients.json` 对此项 0 命中 |
| 2 | `bad-legacy-address-filter.json` 退 2，点名无 `match_response` 那条，**不**点名带 `match_response: true` 那条 |
| 3 | `bad-store-rdrc.json` 四路全中时输出**一行**，来源 `check+schema+table`（去重） |
| 4 | `bad-hysteria-tuning.json` 退 2，来源不含 `run`；用 `SB_FAKE_RUN_LOG` 喂一份没有它的日志时 D 不误报 |
| 5 | `notice-query-type.json` 退 **0**，输出含 `notice` 行与官方链接 |
| 6 | 假内核报 `1.15.3` 时输出「迁移表只覆盖到 1.14.0」一行且退出码不变；报 `1.14.9` 时不打 |
| 7 | `--deep` 用 `SB_FAKE_RUN_LOG` 喂 `sandbox-run.log`：3 条 WARN 全部出现，来源 `run`；`SB_FAKE_UDP=dead` 时打降级 warn 且退出码按 A/B/C |
| 8 | `--apply` 对 `bad-store-rdrc.json`：结构 diff 只有 `experimental.cache_file.store_rdrc` 删、`store_dns` 增，值 `true`；变体（已有 `store_dns`）只删不增 |
| 9 | `--apply` 对 `bad-independent-cache.json`：只删 `dns.independent_cache` |
| 10 | 三条规则同时命中的 fixture：确认提示列出 3 条各自的命中数；`SB_FAKE_MIGRATED` 注入「`store_dns` 值为 false」时第 1 道拒绝 |
| 11 | `dns_rule_strategy` 的 fixture：报告含「建议写法」片段、含 `query_type: ["AAAA"]`、含「无 migration 章节」字样；`prefer_ipv4` 变体不给片段 |
| 12 | 地址过滤 fixture 的片段：两条都含 `query_type`，evaluate 的 `server` 等于原规则的 server（不是 `dns.final`） |
| 13 | 表里每条链接：用 `tests/fixtures/migration-anchors.txt`（从 v1.14.0 `docs/migration.md` 抽出的锚点清单）核对，不许出现清单外的 `migration/#` 锚点 |
| 14 | `SB_LOCKDIR` 指向临时目录时，两个测试文件背靠背各跑一次 `-n restart`，都不出现「另一个 singbox 实例」 |

变异验证（与上一轮同法，实现绿了之后做）：关掉 C 路 → 断言 1/2/4 红；去重逻辑退化为不去重
→ 断言 3 红；`notice` 参与退出码 → 断言 5 红。

### 真内核旁证（只读 fixture，不碰 live）

把 C 路那段 python 抽出来喂真 `sing-box schema` 与 `probe/` 下 17 个 fixture，命中矩阵必须与
本文「问题」一节的实测表一致。这是表条目「谓词写对了」的证据。

### 人工验收（要动 live，已 deny，须本人跑）

```bash
./singbox.sh config audit             # 期望：退 0 或只有 notice；notice 点名 dns.rules 里的 query_type
./singbox.sh config audit --deep      # 期望：沙箱建链成功，D 路无新增发现（live 已迁完 download_detour）
./singbox.sh -n config audit --apply  # 期望：三条规则命中数 0/0/0，「无需改写」
for i in 1 2 3 4 5; do ./tests/run.sh >/dev/null 2>&1 || echo "第 $i 次红"; done   # 期望：无输出
```

外部 API 口径：全部断言针对 **sing-box 1.14.0**（`/sagernet/sing-box`，Context7 ID 在
`.claude/sdlc.json`）；源码引用行号取 git tag `v1.14.0`；sing-tun 取 `v0.9.0-beta.4`
（`go.mod:58`）。

## 实现计划

由 build 于 2026-09-10 追加。基线 `876ccad`，按 5 个可独立验证的单元顺序落地，每单元先写断言看红、
再实现看绿、`sdlc-check`（`./singbox-selfcheck.sh && ./tests/run.sh`）退 0 后提交一次：

| 单元 | 提交 | 内容 | 证据 |
|---|---|---|---|
| U0 锁隔离 | `fd32969` | `LOCKDIR="${SB_LOCKDIR:-…}"`；`tests/run.sh` 每个测试文件一把 `mktemp -d` 下的锁；7 个测试文件的 teardown 从 `rm -rf /tmp/.singbox-sh.lock` 改为删 `$SB_LOCKDIR`（原来那句会删掉 **live** 命令的锁） | 断言 14 先红（`退出 0，没撞上指定目录里的锁`）后绿；连跑 10 次红 0 次 |
| U1 迁移表 | `2b659a4` | `_cfg_pylib`（表 + 路径谓词 + 片段生成）、C 路、按路径去重与来源合并、`notice` 档、`covers` 提示；B 路 walker 认 `allOf` / `unevaluatedProperties` | 18 条断言先红后绿；真内核 1.14.0 对 17 个 probe fixture 的命中矩阵与「问题」表逐行一致；5 个变异全被抓 |
| U2 沙箱日志档 | `07b8cfc` | `--deep`（`_cfg_deep_runlog`，复用 `--apply` 第 3 道那套沙箱）、`_cfg_audit cfg [runlog]`、第 3 道与 `update` 阶段 1 的 `run.log` 喂 D 路、跨 1.14.0 升级打规则集语义 notice、假内核 `run` 的 `SB_FAKE_RUN_LOG` 后门 | 11 条断言先红（`--deep` 仍 `die 尚未实现`）后绿；关掉 D 路读日志 → 4 条红 |
| U3 改写层 | `88e958f` | `_cfg_migrate` / `_cfg_whitelist_diff` 共用表里 `fix: auto` 的 3 条；`_cfg_auto_hits`；确认提示逐条列命中数；命中 0 时「无需改写」早退；第 4 道按命中数归零 | 断言 8/9/10 先红（`store_rdrc` 落地后 diff 为空）后绿；跳过 `rename_if_true` → 5 条红；配对检查 + 新增侧检查同时变异 → T10 红 |
| U4 文档 | 本次 | `config.example.json` 加 `$schema`；`best-practices.md` 的 `$schema` 段与 4.2.1 `dns_mode` 立场；`script-usage.md` 重写 audit 节 + 「迁移表怎么维护」；README、CLAUDE.md、上一轮文档顶部指针 | `sdlc-check` 退 0 |

### 待定问题的裁定

1. `--deep` 等待时长：沿用 `SANDBOX_WAIT=40`，与第 3 道同一套 `_sb_probe_socks`。
2. `legacy_address_filter_rs` 的 notice：裸审查每次都打（真机 live 配置打 2 条）；`--deep` 建链成功而内核没打
   地址过滤 WARN 时**撤掉**（真机验收时发现原实现定性完仍留着「用 --deep 定性」那句，已补）。裸审查嫌吵再改。
3. `snippet` 的 `tag`：带 `mig-af-<原规则下标>`，不查撞名，片段不落地。
4. flaky 根因：基线单跑本来就没红，隔离后 10 次全绿——只能说「隔离后没复现」，不能说根因确认是锁。
5. `covers` 阈值：按 **minor** 比——把内核版本的 patch 位抹成 0 再用三段的 `ver_gt`（1.14.9 不打，1.15.0 打）。

### 实现中发现、与本文不同的事

- **B 路在真内核上对 DNS / 路由规则整段是盲的。** 真 schema 的 `DNSRule` / `Rule` 是
  `oneOf[{unevaluatedProperties:false, allOf:[{匹配字段}, {oneOf: 动作分支}]}]`，上一轮的 walker 不认 `allOf`
  就收手，所以「问题」表里 `strategy` / `rule_set_ip_cidr_accept_empty` 的 schema ✓ 在真机上原本抓不到
  （那两个 ✓ 的依据是源码 `schema:"omit"`，不是 walker 实测）。修 walker 时又踩到 `reject` 分支的 `method`
  枚举含 `""`：「缺键算隐式命中」会把没写 `action` 的规则误归到 `reject`。两处都修了，`schema-min.json`
  照真 schema 的形状重写让测试守住它。修完后 17 个 probe fixture 在真 schema 上零误报。
- 发现行格式**尾部加了可选第 6 列** `snippet`（换行/制表符转义），前 5 列不变；旧消费者（挂载点、verify）不受影响。
- `deprecated.md` 里 `download_detour` 那条的 Migration 链接误指 ACME 一节；v1.14.0 的 `migration.md` 既无
  `download_detour` 也无 `strategy` 的章节。表里这两条链接分别指向 rule-set 配置页的 `http_client` 小节和
  DNS rule action 页的 `strategy` 小节，`note` 里注明。
- `config/config.example.json` 里还有 21 条 `download_detour`（模板没跟着 live 迁）。本文只让它加 `$schema`，
  没动——另立项。
- `tests/fixtures/migration-anchors.txt` 在 U0 提交前就已生成，被一起带进了 `fd32969`。
- review（verifier）抓到合并逻辑两处：表外的 A/D 路发现都以路径 `-` 进合并、互相吞掉（改为无路径的行以原文为去重键）；
  `unknown field X` 在 B 路同键之前处理、贴不上去、报成两行两档（改为 B 路先于 A 路处理）。均已补断言修复。
  未核实的怀疑：直接地址过滤规则与 rule_set 规则共存时，内核那条 WARN 若是全局只打一次，反向定性会误撤 rs 的 notice——
  要真内核核实 `deprecated.Report` 是按 note 去重还是逐规则打。

### 人工验收（要动 live，本人跑）

```bash
./singbox.sh config audit             # 期望：退 0 或只有 notice；notice 点名 dns.rules 里的 query_type
./singbox.sh config audit --deep      # 期望：沙箱建链成功，D 路无新增发现
./singbox.sh -n config audit --apply  # 期望：三条规则 0/0/0 处，「无需改写」
for i in 1 2 3 4 5; do ./tests/run.sh >/dev/null 2>&1 || echo "第 $i 次红"; done
```
