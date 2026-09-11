# 配置审查与一键适配（`config audit`）

## 问题

内核升级会把配置里的字段悄悄变成历史。2026-09-10 实测：本机内核已是 **1.14.0**，而 live 配置里
21 条 `route.rule_set[]` 全部带着 `download_detour`，内核每次启动都在 `/var/log/sing-box.err` 里写：

```
WARN legacy `download_detour` remote rule-set option is deprecated in sing-box 1.14.0
     and will be removed in sing-box 1.16.0.
```

**现有机制对这条告警全程沉默。** 脚本里有 4 处几乎同构的 `grep -qi deprecated`
（`singbox.sh:1179-1181` install 阶段 5、`singbox.sh:1991` `cmd_edit`、
`singbox.sh:2413-2416` `_sb_warn_deprecated`、`singbox.sh:2788` `cmd_doctor`），
它们全都只看 `sing-box check` 的输出 —— 而实测 `check` 对 `download_detour` 一个字都不打：

```
$ sing-box check -c /usr/local/etc/sing-box/config.json
$ echo $?
0
```

于是形成一个闭合的盲区：**告警只在 `run` 时出现，而脚本只在 `check` 时找告警。** 到 1.16.0
字段被真正移除那天，`check` 会从沉默直接跳到 FATAL，配置一次都起不来，而在那之前没有任何
提示会到达用户手里。

这不是 `download_detour` 一个字段的事。官方弃用清单里 1.14.0 一节共 8 条、全部计划在 1.16.0
移除；1.10–1.12 还有一批已经移除的（`legacy inbound fields`、旧式 DNS 服务器格式、
`inet4_address`…）。每次 `update` 升内核，这张表都会长。

## 决定

新增 `singbox config audit`：**用当前安装的那个内核自己**审查配置，报出废弃与不合法之处，
并对其中一条有明确迁移路径的字段提供 `--apply` 一键改写。

**发现层用两路合流，互补彼此的盲区**（两条都是只读、毫秒级、不要 root、不碰网络）：

| 来源 | 抓什么 | 实测依据 |
|---|---|---|
| `sing-box check -c <cfg>` | 废弃但仍接受的字段（WARN，**自带官方 migration 锚点 URL**）；已移除的字段（FATAL，退 1） | `store_rdrc` / `independent_cache` 各报一条 `WARN ... checkout documentation for migration: https://sing-box.sagernet.org/migration/#...` |
| `sing-box schema` 结构比对 | schema 里不存在的键。**sing-box 的 schema 生成器剔除了全部废弃字段**，所以「未知键」集合 ≈ 废弃 ∪ 已移除 ∪ 拼错 | `store_rdrc`/`independent_cache`/`download_detour`/`rule_set_ip_cidr_accept_empty`/`domain_strategy`/`inet4_address` 在 445KB schema 里的出现次数全是 0；新字段 `initial_path`/`match_response` 在 |

`check` 沉默的 `download_detour` 由 schema 档抓到；schema 不认识的「还合法但已废弃」由 check
档定性。两路合流的覆盖面严格大于「沙箱 `run` + check」那条路，而且审的是**配置原件**——
沙箱审的是 `_sb_derive_config`（`singbox.sh:2309-2342`）产出的派生件，它会
`exp.pop("clash_api")`、换端口、改 cache 路径，被改掉的段落里的废弃项就此不可见，
是结构性漏报。**沙箱在本功能里的位置是验收层，不是发现层。**

**改写层只做一条规则**，逐字搬移值：

```json
// 前
{"type":"remote","tag":"geosite-cn","format":"binary","url":"...","download_detour":"vpstrans","update_interval":"7d"}
// 后
{"type":"remote","tag":"geosite-cn","format":"binary","url":"...","http_client":{"detour":"vpstrans"},"update_interval":"7d"}
```

用**内联 `http_client` 对象**，不引顶层 `http_clients[]` 数组、不设 `route.default_http_client`。
理由是实测出来的：`check` 放过 tag 引用错误，只有真跑起来才炸 ——

```
$ sing-box check -c mig-badref.json     # http_client: "rs_dl"，顶层 tag 实为 "rs-dl"
$ echo $?
0
$ sing-box run -c mig-badref.json
FATAL start service: initialize rule-set[0]: create rule-set http client: http_client not found: rs_dl
```

内联写法没有 tag 引用，从源头免疫这一类错误。

**落地姿态**：裸跑 `config audit` 只读出报告；`--apply` 才写 live，且必须走完四道验收。

**退出码**（与 `cmd_verify` 的两档约定同构）：

| 码 | 含义 |
|---|---|
| 0 | 没有废弃项、没有未知键 |
| 2 | 有废弃项但内核仍接受（`check` 的 WARN、schema 未知键而 check 无话）—— 配置现在能跑，将来会坏 |
| 1 | 内核会拒（`check` FATAL）—— 配置已经起不来或升级后必起不来 |

**挂载点**（发现层只读秒级，所以挂进现成流程几乎免费）：

1. `cmd_update` 升级成功后自动跑一次发现层，只报不改，**不影响 update 的退出码与回滚判定**
   —— 内核版本变了，废弃面和 schema 跟着变，这是最该自动检查的时刻，也正是本次问题的成因。
2. `cmd_verify` 新增一档「配置现代性」，挂**策略档**（`vpbad`，退 2），不算链路断。
3. 上述 4 处 `grep -qi deprecated` 全部收敛到发现层的同一个函数，顺便修掉它们只看 `check`
   输出的盲区。

`singbox.sh:2411-2412` 那段注释（「废弃字段照打照记，但一个字都不自动改 —— 改写配置需要读
release notes 与上游文档，验收标准和『安全升级』完全不是一回事」）是被本次推翻的立场，
需要改写成新立场：**发现层自动跑、改写只在 `--apply` 且只走白名单内的 1 条规则、
并以四道验收替代「读 release notes」这个人工前提。**

### 「不更改已配置的功能」怎么机械证明

四道验收，缺一不可。每一道挡的是不同的错，这是按「改写可能出的 6 种错」逐项对照后裁剪出来的：

| 改写可能出的错 | 哪道挡住 |
|---|---|
| ① 漏改：21 条只改了 20 条 | **④ 重跑发现层归零**（前三道全漏 —— 漏改不产生 diff，`check` 沉默，沙箱起得来） |
| ② 值搬错：`http_client:{}` 丢了 `detour` | 四道全漏。**只能靠白名单规则本身精确到值**：新 `http_client.detour` 必须逐字等于旧 `download_detour` |
| ③ 顺手弄坏别的：`json.dump(indent=2)` 重排时误删 `update_interval` | **① 白名单 diff** |
| ④ tag 引用写错 | **③ 沙箱起得来**（`check` 实测放过）；内联写法已从源头免疫 |
| ⑤ 跨段污染：手滑改了某条 `route.rules` 的 `outbound` | **① 白名单 diff** |
| ⑥ 全局默认副作用：`route.default_http_client` 改变所有隐式下载通道 | 四道全漏 → **靠范围排除解决**，见下节 |

1. **离线白名单 diff**：改写前后的 JSON 结构 diff 必须只落在 `route.rule_set[*]` 的
   `download_detour` → `http_client` 上，且值逐字相等。落在别处即拒绝落地。
2. **`sing-box check -c <新配置>`** 通过。
3. **沙箱起得来**：新配置经 `_sb_derive_config` 派生后在沙箱跑，`_sb_health`
   （`singbox.sh:2387`）通过。复用现成沙箱，不改 `singbox.sh:2333`。
4. **重跑发现层归零**：`--apply` 之后再跑一次发现层，`download_detour` 命中数必须为 0。

不做 `/rules` 语义 diff：`download_detour`/`http_client` 是**下载通道**，不进内核解析后的路由表，
在 `GET /rules` 的输出里根本不出现，A 与 B 恒等，对这条规则增量为 0。不跑 `cmd_verify`：
规则集已在 `cache.db` 里，通道变化在缓存未过期时根本不走，同样增量为 0，而代价是分钟级耗时
加 `verify` 本身的偶发假负。

## 不在范围内

1. **`/rules` 语义 diff（`--deep`）不实现。** 只在参数解析里留 flag 位并在 `--deep` 时明确报
   「尚未实现」。它要到迁移表扩进路由语义类条目（`ip_cidr` 无 `match_response`、
   `strategy` DNS 规则操作）时才不可替代，届时还需要把 `singbox.sh:2333` 从
   `exp.pop("clash_api")` 改成换端口保留。
2. **「隐式默认 HTTP 客户端 → 显式 `http_clients` + `route.default_http_client`」只报不改。**
   它是上表的 ⑥ 型改动，四道验收全挡不住，且影响面是全局默认值（`external_ui_download`、
   证书提供者等所有走隐式默认 HTTP 客户端的东西），远超规则集下载。
3. **1.14.0 弃用表其余 6 条、1.10–1.12 的历史废弃，一律只报不改**（报告里给官方 migration
   链接）。本机配置里这些一条都没命中，没有真实样本可验，改写代码只能靠造 fixture，而
   fixture 上的「语义等价」没有真实行为做背书。
4. **不做性能或策略层面的「优化方向」建议**（规则顺序、DNS 策略、规则集合并/拆分…）。
   原始需求里提到「优化的方向」，本轮把范围收在**废弃与合法性**上：那部分已由
   `cmd_verify` 与 `docs/best-practices.md` 覆盖，混进来会让「一键适配」失去可机械验收的边界。
5. **不新增 `singbox-selfcheck.sh` 的自检项。** 那 13 项查的是 shell 写法，本功能不引入新的
   shell 反模式类别。
6. **不碰规则集的自动更新/强制刷新**，也不把 21 条迁到 `type: local`。那是另一件事，
   已在一次面试后放弃立项。
7. **不改 `config/config.example.json` 之外的任何真实配置**：`--apply` 只改 `$CFG`，
   不动订阅、不动凭据、不重排无关字段。

## 受影响的文件与接口

### `singbox.sh`

| 改动 | 位置 |
|---|---|
| 新增 `_cfg_audit <配置路径>` —— 发现层，两路合流，输出结构化行到 stdout | 新函数 |
| 新增 schema 子集校验器（内联 python3，heredoc 一律 `<<'PY'`） | 新函数内 |
| 新增 `_cfg_migrate <配置路径> <输出路径>` —— 白名单改写，1 条规则，值逐字搬移 | 新函数 |
| `cmd_config` 的 `case` 新增 `audit)` 分支 | `singbox.sh:2009-2033` |
| 收敛 4 处 `grep -qi deprecated` 到 `_cfg_audit` | `1179-1181`、`1991`、`2413-2416`、`2788` |
| 改写 `_sb_warn_deprecated` 上方的立场注释 | `singbox.sh:2411-2412` |
| `cmd_update` 阶段 3 之后调用发现层（只报，不影响退出码与回滚） | `singbox.sh:2545` 附近 |
| `cmd_verify` 新增策略档一条（`vpbad`） | `singbox.sh:1658-1792` |
| `cmd_help` 的 `config <sub>` 一行加 `audit` | `singbox.sh:2918` |
| 内核版本闸门：`< 1.14.0` 时 schema 档标为不可信并降级为只用 check 档；`--apply` 在 `< 1.14.0` 上直接 `die`（`http_client` 那时还不存在） | 复用 `ver_gt`（`827`）与 `"$BIN" version \| head -1 \| awk '{print $3}'`（`2472-2480` 同款写法） |

**接口约定**

```
singbox config audit [--config <path>] [--apply] [--deep]
```

- `--config <path>`：审查任意文件而非 `$CFG`。**这条让测试能完全离线**，不需要 live 配置、
  不需要 root。
- 裸跑：只读，退出码 0/2/1 如上。
- `--apply`：走四道验收后写 `$CFG`，回退点用现有 `backup_config`（`singbox.sh:610`）+
  `prune_backups 10`，**不新增第二套备份机制** —— 回退走现成的 `config restore` /
  `config diff`（`singbox.sh:2009-2033`）。
- `--deep`：保留位，报「尚未实现」。

`_cfg_audit` 的每条发现输出一行，TAB 分隔，供调用方自行渲染：

```
<tier>\t<source>\t<json路径>\t<说明>\t<官方迁移链接或空>
```

`tier` ∈ `removed`（对应退 1）/ `deprecated`（退 2）；`source` ∈ `check` / `schema`。
**报告必须点名具体键路径**（如 `route.rule_set[0].download_detour`），不允许只说
「`rule_set[0]` 不匹配任何分支」—— 见待定问题 1。

### 测试

| 文件 | 改动 |
|---|---|
| `tests/config-audit.test.sh` | 新增。全离线，靠 `--config` 指向 fixture |
| `tests/fixtures/bad-download-detour.json` | 新增。带 `download_detour`，必须被点名 |
| `tests/fixtures/good-http-client.json` | 新增。已是内联 `http_client`，必须放行（退 0） |
| `tests/fixtures/bad-removed-field.json` | 新增。带已移除字段，必须退 1 |
| `tests/fixtures/fake-sing-box` | 需新增 `schema` 子命令（当前未实现的子命令一律 `exit 2`，见 `tests/fixtures/fake-sing-box:78-79`）；`check` 的告警沿用已有的 `SB_FAKE_DEPRECATED` 后门 |

fixture 命名沿用现有 `bad-<问题名>` / `good-<写法>` 约定（`tests/fixtures/bad-gnu.sh`、
`good-mv-launcher.sh`）。**注意内联 python3 绕过 PATH 假二进制**
（`singbox.sh:1521,1563` 的注释已记），schema 档的测试需要 `SB_FAKE_*` 式的环境变量后门。

### 文档

| 文件 | 改动 |
|---|---|
| `README.md:155` | 「22 个子命令」计数 |
| `README.md:157-163` | 命令分类表 |
| `docs/script-usage.md:114-127` | 命令速查表 |
| `docs/script-usage.md` | 新增一节讲 `config audit` 与两路合流的盲区互补 |
| `docs/safe-update.md` | 记一笔「阶段 3 之后自动跑发现层」这个新决定（与 `:134` 那条「升级后不自动跑 `cmd_rules`」并列，但是另一件事） |
| `.claude/sdlc.json` | `docs.context7.libraries.sing-box.version` `1.13.14` → `1.14.0`（取实测安装版本） |

## 待定问题

1. **schema 子集校验器的 `oneOf` 错误归因。** `$defs/RuleSet` 是三分支 `oneOf`
   （`inline`/`local`/`remote`，各自 `additionalProperties: false`），带 `download_detour` 的
   条目会同时不匹配三个分支。必须先按 `type` 的 `const` 选定分支再校验，才能报出具体键名。
   没有 discriminator 的分支（如 `$defs/HTTPClientReference` 是 `anyOf: [string, object]`）
   怎么归因，由实现阶段定。**spec 只约束结果**：报告必须点名键路径。—— 责任人：实现者
2. **`< 1.14.0` 的内核，schema 里是否同样剔除废弃字段？** 未实测（手上只有 1.14.0）。
   闸门保守取 1.14.0：低于它只用 check 档。要不要为老内核补兼容 —— 责任人：lzyMeta
3. **`--apply` 的沙箱验收依赖网络。** 沙箱里 `cache.db` 是空的，真配置 21 个 `type: remote`
   规则集冷启动要现下一遍（`docs/safe-update.md:246` 已记，`SANDBOX_WAIT=40` 就是为此加的）。
   网络不通时第三道验收该算失败、还是跳过并降级为「只过了 1/2/4 三道」—— 责任人：lzyMeta
4. **`fake-sing-box` 的 `schema` 子命令吐什么。** 吐一份裁剪过的固定 schema fixture
   （够覆盖 `route.rule_set` 三分支即可），还是吐真内核 schema 的快照（445KB 进仓库）
   —— 责任人：实现者
5. **报告里要不要带 `sing-box schema` 的建议新写法片段。** `$defs/RuleSet` remote 分支
   给出了 `http_client` 与 `initial_path` 的完整结构，可以直接生成可粘贴的 JSON 片段；
   但对「只报不改」的那些条目，生成片段等于在做第 2、3 条被排除的改写工作
   —— 责任人：lzyMeta

## 验证

### 机械验收（离线，进 CI 口径）

```
./singbox-selfcheck.sh && ./tests/run.sh
```

`tests/config-audit.test.sh` 至少断言：

| # | 断言 |
|---|---|
| 1 | `config audit --config tests/fixtures/bad-download-detour.json` 退出码为 **2**，输出点名 `route.rule_set[0].download_detour`（不是「不匹配任何分支」） |
| 2 | `config audit --config tests/fixtures/good-http-client.json` 退出码为 **0**，无任何发现 |
| 3 | `config audit --config tests/fixtures/bad-removed-field.json` 退出码为 **1** |
| 4 | 对 `bad-download-detour.json` 做改写后，结构 diff **只**落在 `route.rule_set[*]` 的 `download_detour`/`http_client` 上，且 `http_client.detour` 逐字等于原 `download_detour`；`update_interval` 等同级字段一字不变 |
| 5 | 改写后重跑发现层，`download_detour` 命中数为 **0** |
| 6 | 在一份「`route.rules[3].outbound` 被额外改动」的伪改写结果上，白名单 diff 必须**拒绝**（防 ⑤ 跨段污染） |
| 7 | 在一份「`http_client` 为空对象」的伪改写结果上，白名单 diff 必须**拒绝**（防 ② 值搬错） |
| 8 | 假内核版本报 `1.13.14` 时，`--apply` 直接失败并说明 `http_client` 需要 ≥ 1.14.0 |
| 9 | `--deep` 报「尚未实现」且退出码非 0 |

### 人工验收（要动 live，已 deny，须本人跑）

```bash
./singbox.sh config audit            # 期望 退 2，点名 21 处 download_detour，附官方 migration 链接
./singbox.sh config audit --apply    # 期望 四道验收全过后落地并重启
./singbox.sh config audit            # 期望 退 0
sudo grep -ci deprecated /var/log/sing-box.err   # 重启后应不再增长
./singbox.sh config diff             # 期望 diff 只有 21 处 download_detour → http_client
```

外部 API 口径：全部断言针对 **sing-box 1.14.0**（`/sagernet/sing-box`，Context7 ID 已在
`.claude/sdlc.json`）。`sing-box schema` 与 `check` 的行为随内核版本变化，升级后这些断言
需要复核 —— 这正是挂载点 1（`update` 后自动跑发现层）要解决的问题。

## 实现计划

2026-09-10 落地。按栈拆成三个单元，各自自带测试、独立跑绿：

| 单元 | 内容 |
|---|---|
| **A 发现层** | `_cfg_audit`（两路合流）＋ schema 子集校验器 ＋ `config audit` 子命令与参数解析 |
| **B 改写层** | `_cfg_migrate` ＋ `_cfg_whitelist_diff` ＋ `_cfg_apply` 的四道验收 ＋ 版本闸门 |
| **C 挂载与文档** | 收敛 4 处 `grep -qi deprecated`、`update` 阶段 3 后、`verify` 第 6 步、README / script-usage / safe-update |

### 三个待定问题的落地结论

| # | 结论 | 谁定的 |
|---|---|---|
| 1 | `oneOf` 归因**有 discriminator 可用**：`$defs/RuleSet` 三分支靠 `type` 的 `const`/`enum` 分派，`$defs/HTTPClientReference` 的 `anyOf` 靠 JSON 类型本身分派（string / object）。报告点名到具体键路径，spec 的约束满足 | 实现者 |
| 2 | 闸门保守取 1.14.0：低于它只用 check 档，`--apply` 直接 `die`。老内核兼容**不做** | 照 spec 的保守方案 |
| 3 | 网络不通时第 3 道**降级为 3/4 道并在输出里明说**，`--apply` 仍落地 | lzyMeta |
| 4 | `fake-sing-box` 的 `schema` 吐一份**裁剪过的 schema fixture**（`tests/fixtures/schema-min.json`，3.7KB，从真内核 schema 程序化裁出），不把 445KB 快照塞进仓库 | 实现者 |
| 5 | 报告**不生成**可粘贴的 JSON 片段，只给官方 migration 链接。生成片段等于把「不在范围内」第 2、3 条排除掉的改写工作挪到人手上，而那些条目本机零命中、没有真实样本可验 | lzyMeta |

### spec 与实测不符的四处

**① `download_detour` 在 schema 里的出现次数是 1，不是 0。**
那一处是 `$defs.ClashAPIOptions.properties.external_ui_download_detour` —— 一个 1.14.0
**仍然有效**的字段。spec 用子串计数得出「全是 0」，撞上了子串包含。

这一条改变了实现：schema 档**必须走结构化键路径比对**，任何 `grep -c download_detour`
形状都会假阳性，而断言 5「改写后命中数为 0」若照子串写，在真配置上永远是假红。
`tests/fixtures/bad-download-detour.json` 里特意保留了这个合法的同名字段，并配一条
「不许误报 `external_ui_download_detour`」的断言，把这个坑钉住。

**② `fake-sing-box` 的 `schema` 子命令不需要新的「绕过 PATH 桩」后门。**
`singbox.sh:1521 / 1563` 那两条注释针对的是**内联 python3 自己去联网**（PATH 桩拦不住）；
这里内联 python3 只**消费** schema 文本，产生它的是 `"$BIN" schema` 这个外部调用，桩完全
拦得住。只加了一个 `SB_FAKE_SCHEMA=<路径>` 给桩**指路**（模板被 sed 到临时目录后 `$0`
已不在仓库里，读不到相对路径），性质与那两个后门不同，已在 fixture 头部注明。

**③ `cmd_doctor` 那处 `grep deprecated` 不在盲区里，没有被收敛掉。**
它的输入 `$out` 里含 `tail "$ERRFILE"`，也就是**内核运行日志** —— 那恰恰是
`download_detour` 告警唯一真正出现的地方。四处里只有它看得见。所以那一行**保留**，
另加一次发现层调用，让 doctor 同时有运行时视角和配置视角。删掉它是退步。

**④ README 的「22 个子命令」计数不用改。** `audit` 是 `config` 的子命令，不新增顶层命令。
改的是分类表里点出 `config audit`，以及 `verify` **五步 → 六步**（这条 spec 没提，但加了
第 6 步不改就是文档与实现不一致）。

### 实现过程中发现的一个真 bug（不在 spec 里）

发现层最初把「内核跑不起来」误判成「配置里有已移除字段」：`$BIN` 损坏、权限不对、根本
没装的时候 `check` 同样退非 0，而那种失败长得跟「内核拒绝配置」一模一样。一个装坏了的
内核会被报成配置有问题，结论完全是误导的。

是 `tests/verify.test.sh` 暴露的——那里 `$BIN` 是个空文件，加上第 6 步之后 16 条断言里
挂了 5 条。修法是在 `_cfg_audit` 开头加前置闸门：`"$BIN" version` 问不出版本号就直接返回；
`_cfg_audit_report` 则明确 `die "内核不可用…审查无法进行"`，不静默报「干净」。

### 变异测试抓出的两条恒绿断言（都是本次自己写的）

实现绿了之后，故意破坏实现跑了三组变异，确认断言不是恒绿的。前两组各抓出一条：

- 「⑤ 拒绝后 live 配置保持原样」原本用 `"download_detour" in json.dumps(...)` 判 ——
  改写后 `external_ui_download_detour` 仍在，子串恒命中。**正是上面 ① 那个坑，写测试时
  自己踩了一遍。** 改成结构化地数 `route.rule_set` 里的命中条数。
- 「② 拒绝时说明了 detour 没搬过来」原本 `grep 'detour'`，而正常输出里到处都是 detour。
  改成钉住实现给出的那句「detour 丢了」。

三组变异的结果（还原后全绿）：

| 变异 | 应该红的断言 |
|---|---|
| 第 4 道（发现层归零）永远通过 | ① 漏改那 2 条 ✓ |
| 第 1 道（白名单 diff）永远通过 | ⑤ 跨段污染 3 条 ＋ ② 值搬错 2 条 ✓ |
| schema 档整个关掉 | 发现层 6 条 ✓（`config audit` 对脏配置退 0） |

另外自检抓到一处 `$CFG，` —— 变量紧贴全角逗号，正是 CLAUDE.md 点名的 bash 3.2 坑。

### 覆盖情况（哪些挂载点有专门断言，哪些没有）

有专门断言的：

- `verify` 第 6 步 —— `tests/verify.test.sh` 里 `$BIN` 是空文件，前置闸门会直接返回，
  那 16 条**从没碰过**第 6 步。所以在 `config-audit.test.sh` 里补了 4 条（脏配置点名 2 处、
  走策略档退 2、干净配置打 ok、第 6 步真的跑了）。
- `update` 阶段 3 之后 —— `tests/update.test.sh` 的现网配置是干净的，那 20 条同样从没触发过
  这个挂载点。补了 2 条独立用例（脏配置下 update **仍退 0 且新内核在位**、日志里确有废弃项），
  用 `store_rdrc` 驱动而非 `download_detour`：后者只有 schema 档看得见，而那条用例升的是
  1.13.19，schema 档被版本闸门关掉了。
- `--apply` 的第 3 道（沙箱）—— 用 `SB_FAKE_UDP=alive` / `dead` 各跑一条，确认它既会真跑
  也会降级。只测降级路径的话第 3 道就是死代码。

**没有专门断言的**：`install` 阶段 5、`edit` 校验后、`doctor` 自动判读三处收敛。它们与
`update` 挂载点同构（都调 `_cfg_audit_notice`，返回值恒 0、只 `warn`），契约已由 update
那 2 条覆盖；`install.test.sh` / `cli.test.sh` 的回归证明没改坏。残余风险：这三处的新输出
文案没有被钉住。

### 评审（`/sdlc-kit:review`）抓到的两条，都已修

**① 发现层用 sudo，且「审不了」被报成了「配置已经坏了」。**（推翻了上面「实现过程中
发现的一个真 bug」那节的完成声明——前置闸门只挡住了 `$BIN` 那一半。）

`_cfg_audit` 原先对 `$CFG` 跑的是 `sudo "$BIN" check`。**sudo 自己失败时同样 `rc != 0`**，
输出里没有 `unknown field`，于是走兜底分支把 sudo 的错误行整行当成一条 `removed` 发现：

```
  [removed/check] -
      sudo: a terminal is required to read the password; ...
  ✗ 1 项已被本版本内核移除，配置起不来
EXIT=1
```

后果比误报更重：`cmd_verify` 原先**通篇没有一次 sudo**（1-5 步只有 curl/dig/ping，也没有
`need_root`），第 6 步让一个只读诊断命令第一次开始要提权，于是干净配置在无 TTY 环境
（cron、`ssh host singbox verify`）下会退 2 —— 而 `update` 阶段 3 读的正是这个退出码。
需求来源 §决定 和 §接口约定 两处都写明发现层「不要 root」。

测试抓不到它，因为 `tests/fixtures/bin/sudo` 是个恒成功的透传桩。

修法分三层：

1. **发现层彻底去 sudo**。`sing-box check -c` 只读配置，`$CFG` 是 644，本来就不需要提权。
   `_cfg_apply` 第 2 道的 `sudo "$BIN" check` 一并去掉（`$new` 是 `mktmp` 建的）；真正需要
   root 的只有落地那几行，那里本来就有 `need_root`。
2. **把「审不了」和「配置坏了」分开**。`_cfg_audit` 的返回值从此有意义：0 = 审完了，
   1 = 审不了。判据是输出像不像内核自己的诊断（有 `unknown field`，或至少有 `FATAL`）；
   两样都没有就是审查本身没做成，返回 1，**不产生任何发现**。
3. **各调用方分别处置**：`config audit` 明确 `die "审查没做成…这不代表配置没问题"`；
   `verify` 第 6 步打 info 跳过、**不 vpbad**；`_cfg_audit_notice`（install/edit/update/doctor
   四个搭车的挂载点）静默退场；`_cfg_apply` 第 4 道**拒绝落地**——那一道是漏改的唯一防线，
   跳过它等于四道只剩三道。

顺带修正同一类误导的反方向：前置闸门原先在内核问不出版本号时 `return 0`（＝审完了、
没发现），会让 verify 打出「配置里没有废弃字段」。改成 `return 1`。

**② `inlog '沙箱'` 是恒绿断言，「第 3 道真跑了」那一路其实没被覆盖。**

`step "验收 3/4　沙箱起得来"` 是无条件打印的，降级分支的 warn 里也写着「沙箱」二字 ——
把整段沙箱代码删掉换成 `passed=3`，那条断言照样 PASS。改成钉住只有真跑才会出现的
`沙箱建链成功`，外加 `! inlog '只过了 3/4 道'`（不能只写 `3/4`：会撞上 step 标题「验收 3/4」，
那是假红）。

### 补上的回归防线

评审那条 bug 的原始形状——「文件可读，但 check 退非 0 且输出一个字都不像内核诊断」——
原先没有任何东西能驱动它（`chmod 000` 会被 `[ -r "$cfg" ]` 提前拦下，走不到兜底分支）。
给 `fake-sing-box` 加了 `SB_FAKE_CHECK_NOISE=1`：check 退 1，只吐一行
`sudo: a terminal is required to read the password`。配套 2 条断言钉住「不是内核在说话就
不许报 removed」。变异验证：把兜底分支退回原样，这 2 条立刻红。

`tests/verify.test.sh` 那 16 条是这条防线的另一半——那里 `$BIN` 是空文件，第 6 步走的正是
「审不了 → 跳过」分支，它们全绿就意味着 verify 没有被审查失败带偏。

### 走人工验收前补的两处

对着 spec §验证 的人工验收步骤逐条比对时，发现实现漏了两件 spec 明写或脚本通用约定要求的事：

1. **`--apply` 落地后没有重启服务。** spec §验证 写的是「四道验收全过后落地**并重启**」，
   而实现只写文件就返回了 —— 内核还在跑旧配置，`sing-box.err` 里的 deprecated 告警不会停，
   验收第 4 步（`grep -ci deprecated` 不再增长）永远对不上。`cmd_config restore` 本来就是
   用 `cmd_restart` 收尾的，照它补上。
2. **`--apply` 不认全局 `-n`。** 干跑是这个脚本的通用约定（`cmd_edit` 就有），而 `--apply`
   改的是 live 配置，恰恰最该能先预演。四道验收本身全是只读的，所以 `-n` 在**落地那一步**
   收手就够了 —— `-n config audit --apply` 是一次完整预演：会改成什么、四道过不过，全说清楚，
   只是不写盘。

顺带加了一次落地前确认（`ask`，**默认 y**）。默认不能写 n：`ask` 在 `-y` / 非交互下取的是
**默认值**而不是「一律同意」，写 n 会让自动化场景永远落不了地。

两处都补了断言，并各自变异验证过（拿掉 `-n` 分支 → 「配置一个字节都没被写」红；拿掉
`cmd_restart` → 「落地后重启了服务」红）。

### 落地的结构

```
_cfg_audit          发现层，两路合流，输出 TAB 行。**不用 sudo。**
                    返回 0 = 审完了 / 1 = 审不了（这两件事不能混）
_cfg_audit_report   渲染 + 按 tier 定退出码（0/2/1），config audit 用
_cfg_audit_notice   挂载点专用：只报，返回值恒 0，不参与调用方的成败判定；审不了就静默退场
_cfg_migrate        改写层，一条规则，逐字搬移；SB_FAKE_MIGRATED 是测试注入点
_cfg_whitelist_diff 第 1 道，结构 diff（不是文本 diff）
_cfg_apply          四道验收 + 版本闸门 + backup_config/prune_backups 落地
```

`SB_FAKE_MIGRATED` 存在的理由：不给这个注入点，第 1 道验收就只能被自己产出的**正确**
结果喂 —— 它永远绿，也就永远测不出它到底拦不拦得住。断言 6/7 和「① 漏改」三条都靠它。

### 验证

```
./singbox-selfcheck.sh && ./tests/run.sh     # 退出码 0
```

160 条断言全绿，其中 `tests/config-audit.test.sh` 48 条：

| 覆盖 | 条数 |
|---|---|
| 发现层（退出码三档、键路径点名、两路各自的来源、不误报同名子串与 `type: local`） | 16 |
| `--apply` 四道验收（含 ①②⑤ 三型错各自被哪道拦住、版本闸门、3/4 降级与完整路径） | 17 |
| `verify` 第 6 步挂载点 | 4 |
| 「审不了 ≠ 有问题」（评审后补） | 7 |
| `-n` 干跑不写盘、落地后重启（人工验收前补） | 4 |

⚠️ **`./tests/run.sh` 连跑会偶发 2 条红**（`cli` 的 `-n restart`、`selfupdate` 的
「远端 == 本地」），报的是 `另一个 singbox 实例正在运行（PID …）` —— 全局互斥锁争用，
单独重跑各自全绿。这是**既有的** flakiness，不是本次改动引入的，但值得单列一笔。

真内核旁证（1.14.0，只读 fixture，不碰 live 配置）：把 `singbox.sh` 里 schema 档那段
python 原样抽出来喂真 schema —— `bad-download-detour.json` 恰好 2 条命中且都是
`route.rule_set[N].download_detour`、没有误报 `external_ui_download_detour`；
`good-http-client.json` 0 条；`bad-removed-field.json` 真 schema 还多抓到
`inbounds[1].inet4_address`（真 schema 约束 `inbounds`，裁剪版不约束）。

### 真机人工验收：已完成（2026-09-10，sing-box 1.14.0，live 配置 21 条 `rule_set`）

| 步 | 命令 | 结果 |
|---|---|---|
| 1 只读审查 | `config audit` | 退 **2**；恰好 21 行 `route.rule_set[0..20].download_detour`；**来源栏全是 `schema`，一条 `check` 都没有**（check 对它全程沉默，spec 开头那个盲区的真机证据）；`external_ui_download_detour` 一次都没冒出来（live 配置里确实有这个合法字段） |
| 2 干跑 | `-n config audit --apply` | 四道全过，第 3 道**真跑**（`沙箱建链成功，出口 95.169.17.163`，21 个 remote 规则集在空 cache 上下完了），落地前收手，配置未动 |
| 3 落地 | `config audit --apply` | 用 `!` 前缀跑时被 `need_root` 挡住（无 TTY，sudo 要不到密码）—— **配置一字未动**，`need_root` 排在 `backup_config` 之前。在终端重跑后落地，备份 `config.json.20260910-192012.bak`，服务已重启 |
| 4a 归零 | `config audit` | 退 **0**，`✓ 没有废弃项，也没有未知键` |
| 4b 结构 diff | 对最新备份做扁平化比对 | 删 21 键（全是 `.download_detour`）、增 21 键（全是 `.http_client.detour`）、**值变了的 0**、**白名单外的改动 0**；搬移的值去重后只有 `vpstrans`；文件 10,791 → 11,379 字节，差 588 = 21 × 28 |
| 4c verify | `verify` | 六步全过，退 **0**，第 6 步 `✓` |
| 4d 日志增量 | `sudo grep -ci deprecated /var/log/sing-box.err` 隔时段两次 | 计数**没有增加**（lzyMeta 在终端核对）—— 重启后内核不再写 `download_detour` 告警，改动确实生效了 |

验收过程中顺手修的：`verify` 前五步的标题分母还是 `/5`、第六步却是 `6/6` —— 加步骤时漏改。
统一成 `/6`，README 与 script-usage 里的「五步」同步；`docs/safe-update.md` 里的「五步」是
那份 spec 落地时的历史记录，不动。

一处记下不改的：`need_root` 打的「TUN 建虚拟网卡、改路由表必须 root」是给 `install` 写的
文案，落在 `--apply` 上不贴切。不阻塞，不在本轮范围。
