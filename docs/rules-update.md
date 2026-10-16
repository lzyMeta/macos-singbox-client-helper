---
kind: spec
status: building
prototype: none
covers:
  - singbox.sh
  - tests/rules.test.sh
  - tests/fixtures/bin/launchctl
  - tests/fixtures/bin/curl
  - docs/manual-check.md
appetite: {diffLines: 400, phases: 3}
---
# `rules update`：手动强制重下全部 remote 规则集

## 问题

sing-box 的 remote 规则集只在两种时刻下载（1.14.3 源码 `route/rule/rule_set_remote.go` 与
`rule_set_updater.go`，2026-10-15 实测）：本地没有缓存时启动，同步下载，任一失败就 `FATAL … initial rule-set` 退出；
运行中按 `update_interval` 到期更新，本配置是 `168h`。上次更新时间存在 `cache.db` 里，**重启不会重置计时，也不会提前触发**。
Clash API 的 `PUT /providers/rules/:name` 是空实现（`experimental/clashapi/ruleprovider.go`），面板上的「更新」按钮不起作用。

所以下面这些时刻，人没有办法让规则集立刻更新：

- 上游刚修了一个分类，比如某个域名被误归类；
- 内核大版本升级之后，best-practices 建议重下一次（srs 有格式版本）；
- `doctor` 报了 `规则集更新失败`，修好代理之后想马上验证，而不是再等 7 天。

现在唯一的办法是手工停服务、删 `cache.db`、再启动。这样做有三个坑：

1. 只要有一个 URL 不通，内核就起不来，**人会在断网状态下发现这一点**；
2. 旧缓存被删掉了，没法退回去；
3. 面板上切过的 clash 模式（Rule / Global / Direct）也存在 `cache.db` 里，会悄悄回到默认值。

外部可抄的实现：没有。sing-box 不提供这个能力，本仓库的 `cmd_update` 阶段 2（备份 → 换 → 起 → 失败回滚）是最近的先例。

## 决定

新增子命令 `singbox rules update`，不带参数的 `singbox rules` 行为不变（只验 URL 可达）。执行顺序如下：

1. **前置条件**：
   - 服务必须在运行，否则拒绝并提示先 `start`。不在运行时没有代理可用，预检只能直连，在国内多半不通。
   - 配置里的 `experimental.cache_file` 必须已开启，否则拒绝并提示：没有缓存时每次启动都会重下，`restart` 就够了。
   - 缓存路径从配置的 `experimental.cache_file.path` 读。相对路径按 launchd 的 `WorkingDirectory`（`$ETC`）解析；没写就是 `$ETC/cache.db`。不再写死 `$ETC/cache.db`。
2. **预检**：复用 `cmd_rules` 的逻辑，经正在运行的代理逐个请求 URL。**有任何一个不是 200，就不动服务**，退出 1，并列出不通的 tag。
3. **确认**：问一句「会断网几秒」，默认 y。`-y` 跳过确认，`--dry-run` 只打印计划。
4. **记下 clash 模式**：配置里开了 `clash_api` 时，用 `GET /configs` 读出当前 `mode`（`secret` 有就带上），否则跳过。
5. **换缓存**：停服务（不碰 DNS，同 `restart` 的 `--keep-dns`）→ 把 `cache.db` 移成 `cache.db.prev`（覆盖上一份）→ 启动服务。
6. **验收**：服务起来并通过 `_sb_health` 就算成功。这一步已经足够：无缓存时内核要把全部规则集同步下完才算起来。
7. **成功**：
   - 如果第 4 步记下了模式，就用 `PATCH /configs` 写回。写回失败只 warn，不回滚。
   - 保留 `cache.db.prev`，打印手动退回的步骤。
   - 退出 0。
8. **失败**（起不来，或 health 不过）：停服务 → 把 `cache.db.prev` 移回 `cache.db` → 再启动。这次走有缓存的路径，下载失败不会阻止启动。然后打印 `_launchd_postmortem`，退出 1。

内核升级成功后，`update` 只多打印一行「可跑 `singbox rules update`」，不自动调用。

因此什么会变差：

- 强制更新期间会断网几秒（TUN 拆掉再建）。失败时会断两次。
- `cache.db` 里的 `selected` / `group_expand`（selector 的选择、面板分组的展开状态）不会被保存和写回。模板里没有 selector，用户自己加了的话，选择会回到默认。
- 预检走的是 curl 加 socks 代理，内核下载走的是 `http_client.detour`，两条路径不完全一样。所以预检通过不等于内核一定能下成功，最后兜底的是第 8 步的回滚。

**备选与否决**
- 只靠回滚、不预检 —— 分类名写错（404）这种明显问题，也要先断网再回滚一次。预检能在不停服的情况下拦下大部分。
- 验收时再跑 `_sb_verify_rounds` 并按结果回滚 —— 多花几十秒，而 verify 不过的原因多半和规则集无关（比如节点问题），按它回滚规则集是错把账算到规则集头上。
- 服务没在运行时跳过预检、只靠回滚 —— 服务都没起，本来就得先起一次服，没有「更新」可言。
- `update` 成功后自动跑一次 —— 会把规则集失败和内核失败搅在一起，`update` 的回滚语义也会变复杂。
- 用 bbolt 工具只删 `rule_set` bucket，保留其余状态 —— macOS 没有现成的 bbolt 工具，引入一个二进制依赖不值得。
- 加 `rules rollback` 一键退回 —— 功能面更大。保留 `.prev` 加文档里写清楚步骤，已经能覆盖低频的退回需求。
- 改 URL 让哈希对不上，从而触发重下 —— 要改用户的配置，而且同样要重启，没有省下任何东西。

## 不在范围内

- **按 tag 只更新部分规则集**：`cache.db` 是一整份 bbolt 文件，没有 bbolt 工具就只能整份换。
- **`rules rollback` 命令**：只保留 `cache.db.prev`，退回步骤写在 `docs/manual-check.md`。
- **`update` 自动强制更新规则集**：只打印一行提示。
- **服务没在运行时的更新**：拒绝，提示先 `start`。
- **定时强制更新**（比如 launchd 每周跑一次）：内核自己的 `update_interval` 已经覆盖了周期更新。
- **保存和写回 selector 选择、`group_expand`**：只处理 clash `mode`。
- **改 `update_interval` 或其他规则集字段**：本命令不改配置。

## 受影响的文件与接口

| 路径 | 处置 | 改动 | 落点理由 |
|---|---|---|---|
| `singbox.sh` `cmd_rules`（:1869） | 扩展 | 加参数解析：无参数 = 现有验证；`update` = 强制更新；其他参数 die。把 URL 列表和逐个探测抽成一个 helper，验证和预检共用 | 已承载规则集的全部动作；先例是 `cmd_config` 的 `export` / `audit` 子动作 |
| `singbox.sh` 分发与参数门卫（:4601 不接受参数列表、:4620 `rules)`） | 扩展 | 从「不接受参数」列表里去掉 `rules`；分发行改成转发 `ARGS`，照 `config)` 那一行 | 唯一入口 |
| `singbox.sh` `cmd_stop` / `cmd_start` / `_sb_health` / `_launchd_postmortem` / `acquire_lock` / `need_root` / `ask` | 复用 | 停服用 `--keep-dns`；验收与验尸原样调用 | `cmd_update` 阶段 2 已经证明这套组合可用 |
| `singbox.sh` clash_api 读写模式 | 新建 | 一个 helper：从配置读 `external_controller` 和 `secret`，`GET` / `PATCH /configs` | —— 仓库里没有任何调用 clash_api 的代码，`sock_addr` 只认 mixed/socks 入站，承载不了 |
| `singbox.sh` 缓存路径解析 | 新建 | 一个 helper：读 `experimental.cache_file.enabled` / `path`，相对路径按 `$ETC` 解析 | —— 现有唯一读这个键的地方是 install 第 4 步的改写（:1129），它判的是「是不是相对路径」，不返回路径；`cmd_rules` 里是写死的 |
| `singbox.sh` `cmd_update` 收尾 | 扩展 | 成功后多打印一行提示 | 已有收尾提示段 |
| `singbox.sh` `cmd_help`（:4523） | 扩展 | `rules` 行补上 `rules update` | 帮助文本唯一出处 |
| `tests/fixtures/bin/launchctl` | 扩展 | 新开关：启动时如果 `cache.db` 不在，就按 FATAL 的形状演（进程不出现）；把每次 bootstrap 时 `cache.db` 是否存在记进事件日志 | 已用 `SB_FAKE_START_FAIL` / `SB_FAKE_BTM_PIN` 承载「起服成败」 |
| `tests/fixtures/bin/curl` | 扩展 | 让 `/configs` 的 GET / PATCH 读写 `$SB_FAKE_STATE` 里的 mode；新开关让某个规则集 URL 探测失败 | 已承载 URL 探测与 socks 分流 |
| `tests/rules.test.sh` | 新建 | 覆盖下面全部 AC | —— `rules` 没有测试文件；放进 `update.test.sh` 会把规则集和内核两条状态机混在一起 |
| `CLAUDE.md` | 扩展 | 测试文件计数（`sdlc-doc:n` 标记）与清单里加上 `rules` | `docs.test.sh` 核对计数 |
| `README.md`、`docs/manual-check.md`、`docs/best-practices.md`（:829「手动触发一次规则集更新」） | 扩展 | 写上 `rules update` 的用法、失败语义和手动退回 `.prev` 的步骤；best-practices 原来「停服、删 `cache.db`、再起」改成指向本命令 | 现有描述规则集更新的位置 |

（本表行号只在 build 期间有效；shipped 后不保证，以文件名为准。）

## 待定问题

- 用户自己加了 selector 时，选择会回到默认：按假设处理，配置里有 `selector` / `urltest` 出站时，成功后打印一行提示，不保存不写回 —— 用户
- `clash_api.external_controller` 绑在 `0.0.0.0` 或 IPv6 地址上时，请求一律改走 `127.0.0.1:<端口>` —— 已定
- 面板模式写回失败（`secret` 不对、API 没起来）只 warn、不回滚 —— 已定

## 验证

### 验收条件

- AC1 ★ 服务在运行、URL 全部可达时，`rules update` 依次停服 → 把 `cache.db` 移成 `cache.db.prev` → 启动，**启动那一刻 `cache.db` 不存在**，health 通过后退出 0，`cache.db.prev` 的内容等于原来的缓存，DNS 没被改。反例：不移走 `cache.db` 直接重启（等于普通的 `restart`），「bootstrap 时 `cache.db` 不存在」这条事件断言会红。
- AC2 预检有一个 URL 不是 200 时，退出 1，**没有发生任何 bootout**，`cache.db` 字节不变，输出点名那个 tag。反例：预检失败只 warn 然后继续，bootout 事件断言会红。
- AC3 启动失败（假 launchctl 在没有缓存时不让进程出现）时，把 `cache.db.prev` 移回 `cache.db` 再启动，最终服务在运行、`cache.db` 等于原来的内容，退出 1。反例：去掉回滚，服务停着的断言会红；回滚时忘了移回缓存，第二次启动也起不来，同样红。
- AC4 服务没在运行时拒绝，退出非 0，提示 `start`，不发生 bootout，`cache.db` 不动。反例：去掉这道前置检查，bootout 事件断言会红。
- AC5 配置里开了 `clash_api`、更新前 mode 是 `Global` 时，成功后 mode 仍是 `Global`（PATCH 被调用过）；没开 `clash_api` 时不发请求，只打印一行跳过提示。反例：不做写回，mode 断言会红。
- AC6 缓存路径以配置为准：`cache_file.path` 指向自定义的绝对路径时，移走的是那个文件；`cache_file` 没开启时拒绝并提示 `restart`，不发生 bootout。反例：写死 `$ETC/cache.db`，自定义路径的用例会红。
- AC7 `--dry-run rules update` 只打印计划，不发生 bootout，`cache.db` 不动，退出 0。反例：DRY 只拦了 `run()` 而 `cmd_stop` 照样执行，bootout 事件断言会红。
- AC8 不带参数的 `rules` 输出和退出码不变；`rules foo` 报未知参数并退出非 0；`help` 里列出 `rules update`。反例：分发行没转发 `ARGS`，`rules update` 会落成普通的验证，AC1 会红。
- AC9 `update` 内核升级成功后，输出里有一行提示 `rules update`；失败、回滚的路径不打印。反例：把提示放在阶段 3 之前，回滚用例里也会出现，红。

### 检查命令

```bash
./singbox-selfcheck.sh && ./tests/run.sh
```

真机验收（人跑，`rules update` 会动 launchctl，已 deny）：`sudo ./singbox.sh rules update`，再看 `ls -l /usr/local/etc/sing-box/cache.db*`，以及日志里每个 tag 都有一条 `updated rule-set`。

## 实现计划

基线：ee7d7e893110d80615d0c0eb48f04ca4b55c9598

- [ ] U1 分发与参数解析、`_rules_list` / `_rules_probe` 抽取、`_sb_cache_path`、前置条件、预检、`--dry-run`（AC2、AC4、AC6 拒绝半、AC7、AC8）
- [ ] U2 停服等进程退净 → 移缓存 → 起服 → 轮询就绪 → `_sb_health`；失败换回 `.prev` 再起（AC1、AC3、AC6 自定义路径半）
- [ ] U3 clash `mode` 读出与写回、selector / urltest 提示（AC5）
- [ ] U4 `update` 收尾提示（AC9）、文档（README、manual-check、best-practices 两处、CLAUDE.md 计数与清单）、`shipped`

### 文件（沿用处置表，补两行表外文件）

| 路径 | 处置 | 改动 | 落点理由 |
|---|---|---|---|
| `singbox.sh` | 复用 → 扩展 → 新建 | 同上表各行 | 同上表 |
| `tests/fixtures/bin/launchctl` | 扩展 | `SB_FAKE_CACHE_DB=<路径>`：bootstrap 时记 `cache:present` / `cache:absent` 进 `btm_events`；缓存不在时 `SB_FAKE_NOCACHE_FAIL=1` 则进程不出现，否则生成一份新缓存并清掉 `$S/clash_mode`（无缓存起来回到默认模式） | 已承载起服成败 |
| `tests/fixtures/bin/curl` | 扩展 | 接住 `-w` / `-X` / `-H` / `-d`；`.srs` 且 `-w` 含 `http_code` 时直接往 stdout 写 200，URL 含 `SB_FAKE_RULE_FAIL` 写 404（放在代理分支之前，否则落进 verify 分支）；`*/configs` 的 GET / PATCH 读写 `$S/clash_mode`，事件进 `$S/clash_events`，`SB_FAKE_CLASH_SECRET` 校验 Bearer | 已承载 URL 探测 |
| `tests/fixtures/bin/networksetup` | 扩展（表外） | `-setdnsservers` 记进 `$S/dns_events`，「DNS 没被改」才有事件可断言 | 唯一的 DNS 写入口 |
| `tests/update.test.sh` | 扩展（表外） | 第 1 条（成功）断言日志含 `rules update`，第 6 条（阶段 3 回滚）断言不含 | AC9 是 `update` 的输出，复用那里的升级装置；不把内核状态机搬进 `rules.test.sh` |
| `tests/rules.test.sh` | 新建 | AC1–AC8 | 同上表 |
| `CLAUDE.md`、`README.md`、`docs/manual-check.md`、`docs/best-practices.md`（:829、:1684） | 扩展 | 同上表；README 仓库结构加 `rules.test.sh`，去掉两处「待实现」 | 同上表 |

### 顺序

U1 → U2 → U3 → U4。每个单元先写断言、跑红，再写实现。

### 怎么证明它可用（逐条 AC）

测试装置：`rules.test.sh` 自写配置，`cache_file.path` 与 `SB_FAKE_CACHE_DB` 都在 `$ROOT` 下（sudo 桩对 `mv` 是真执行，照抄 `update.test.sh` 的 `/usr/local/...` 会去搬 live 缓存）；`SB_FAKE_DNS=1.1.1.1`（= `PROXY_DNS`），否则 `cmd_start -y` 自己就会写 DNS；两条 remote `.srs` 规则集。

| AC | 测试用例 | 反例怎么让它红 |
|---|---|---|
| AC1 | 正常路径：退 0；`btm_events` 是 `bootout` 后接 `cache:absent`；`.prev` 内容 = 原缓存；新 `cache.db` 存在；`dns_events` 为空 | 不移缓存 → `cache:present`；漏 `--keep-dns` → `_maybe_restore_dns` 默认 y 写 DNS |
| AC2 | `SB_FAKE_RULE_FAIL=<tag>`：退 1，无 `bootout`，缓存字节不变，日志含该 tag | 预检只 warn → 出现 `bootout` |
| AC3 | `SB_FAKE_NOCACHE_FAIL=1`：退 1，`running`=1，`cache.db` = 原内容，第二次 bootstrap 是 `cache:present` | 去掉回滚 → `running`=0；忘移回 → 第二次 `cache:absent` 又起不来 |
| AC4 | `running`=0：退非 0，日志含 `start`，无 `bootout`，缓存不动 | 去掉前置检查 → 出现 `bootout` |
| AC5 | `clash_mode=Global` + `SB_FAKE_CLASH_SECRET`：成功后 `clash_mode` 仍是 `Global` 且 `clash_events` 有 PATCH；去掉 `clash_api` 的配置：`clash_events` 为空、日志有跳过提示 | 不写回 → 无缓存起服把 `clash_mode` 清回默认，断言红 |
| AC6 | `path` 指向 `$ROOT/custom/c.db`：移走的是它（它的 `.prev` 存在，`$ETC/cache.db` 不出现 `.prev`）；`enabled:false`：退非 0、提示 `restart`、无 `bootout` | 写死 `$ETC/cache.db` → 自定义用例红 |
| AC7 | `-n rules update`：退 0，无 `bootout`，缓存不动 | DRY 只拦 `run()` → 出现 `bootout` |
| AC8 | 无参数 `rules`：退 0，输出含「全部 2 个规则集可达」；`rules foo` 退非 0 且点名 `foo`；`help` 含 `rules update` | 分发不转发 `ARGS` → `rules update` 落成验证，AC1 红 |
| AC9 | `update.test.sh` 第 1 条 / 第 6 条 | 提示放在阶段 3 之前 → 第 6 条红 |

实现要点（advisor 审过）：
- `cmd_start` 只等 2 秒就查 `running`，可无缓存起服要同步下完全部规则集，下载期间端口没在听、TUN 没接管。所以起服后先**轮询就绪**（进程在且端口在听，最多 120 秒；进程消失立即判失败），再跑一次 `_sb_health`，否则会把一次正在成功的更新当成失败回滚。
- `cmd_stop` 进程没退也只 warn、返回 0，接着 `cmd_start` 看到 `running` 会报「已在运行」并退 0，结果什么都没换就报成功。所以停服后照 `_sb_restart_reload` 等最多 10 秒，进程仍在就中止，不动缓存。
- `/configs` 的 GET / PATCH 在片段库里**没有权威来源**（`sdlc-docs` 只取到 `external_controller` 6067da17 与 `default_mode` 75065ba4），依据是本 spec 引的 1.14.3 源码；评审重点看这一段。

### 粒度

```
files=11  stacks=1 (main)  contracts=0  unscoped=0  verdict=warn
created=1
```

单栈 11 个文件：4 个文档、3 个假桩扩展是机械的；实现只在 `singbox.sh`，已按 4 个单元拆开。

