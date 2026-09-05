# 内核安全升级（update 重做 + rollback）

## 问题

`cmd_update`（`singbox.sh:1409-1447`）从来没有被实跑验证过，而代码里有三处会在「新内核有大改动」
这个正好最需要它的场景下失效：

**① 回滚点在重启之前就被删掉了。**

```bash
sudo rm -f "$BIN.prev"      # singbox.sh:1431
cmd_restart                 # singbox.sh:1432 —— 返回值也没有被检查
```

`sing-box check -c` 通过、但新内核起不来（或起来了但代理坏了）时，旧二进制已经不在。
这不是理论风险：内核迭代快，`1.11` 的 DNS 格式不兼容、`domain_strategy` 在 `1.14` 被移除、
`independent_cache` 在 `1.14` 废弃（`README.md:54`、`docs/script-usage.md:392`）。

**② 判定只有静态一层。** `check -c` 校验的是配置文件的语法与字段合法性。字段还在、语义变了
（升级风险里的「配置逻辑改变」）它照样过。仓库里已经有一套五步功能验证 `cmd_verify`
（`singbox.sh:996`），但 `update` 一次都没调用它。

**③ 下载的内核没有任何完整性校验。** 解压结构检查之外，拿到的字节是什么没人核对过。

## 决定

把 `update` 从「下载 → 换 → 静态校验 → 重启」改造成**四个阶段，每个阶段都能回到一个已知可用的
状态**；并新增 `rollback` 子命令，把回滚从「升级过程中的一个分支」变成「任何时候都能按的按钮」。

**阶段 0 · 预检（不下载）**
取当前版本与目标版本。**minor 号发生变化时额外确认一次**（`ask` 默认 `n`，所以 `-y` 非交互模式
下会跳过升级而不是闷头升），提示这类升级历史上移除过字段。

**阶段 1 · 沙箱（现网服务继续跑，完全不受影响）**
装到临时前缀（复用已有的 `--prefix`），然后：

1. 新内核 `version` 能跑（架构、OS 版本、quarantine 属性都在这一步暴露）
2. 新内核 `check -c` **当前真实配置** —— 静态兼容性
3. **派生一份沙箱配置**并用新内核实跑，`curl -x socks5h://` 实测能否建链

派生是必须的：真配置里有 `tun` inbound、`mixed` 监听 `127.0.0.1:10808`、
`experimental.cache_file.path` 指向 `/usr/local/etc/sing-box/cache.db`。现网服务在跑时，
第二个实例会在这三处全部冲突。派生规则：

- 删掉 `type == "tun"` 的 inbound
- `mixed` 的 `listen_port` 换成一个探测到的闲置端口
- `cache_file.path` 指到临时目录

⚠️ **派生用 `python3`，不要引入 `jq`。** 脚本目前对 `jq` 零依赖，但 `python3` 已经是硬依赖
（`singbox.sh:160` 的必需命令清单，以及 `:186`、`:200` 的 `json_valid`、`:652` 已有的用法）。
沿用现成写法，不新增依赖。

**阶段 2 · 升级（此时才动现网）**
`$BIN` → `$BIN.prev`，装新内核，`check -c`，`cmd_restart` **并检查返回值**，然后确认三件确定性
的事：进程存活、TUN 路由存在、监听端口在听。任一不成立 → 回滚。

**阶段 3 · 验收**
跑 `cmd_verify` 五步。**五步全部算硬失败**，但失败时隔几秒重试一轮，两轮都不过才回滚——
第 2/3/4/5 步依赖 `ipinfo.io` / `dig` / `cloudflare-quic.com` / `cip.cc`，一次抖动不该把一次
成功的升级回滚掉。

**成功之后 `$BIN.prev` 保留**，留到下一次 `update` 才被覆盖。这覆盖了「当时一切正常，半小时后
才发现某个网站进不去」——那时 `singbox rollback` 一条命令换回去、重启、跑一遍阶段 3 的验收。

## 不在范围内

1. **基于新内核的配置优化方案。** 「哪些字段该改成什么写法」需要读 release notes 与上游文档、
   需要判断力，验收标准与本功能完全不同。**另开一份 spec**，本轮只做安全升级。
2. **自动改写配置。** 废弃字段告警照打、照记，但一个字都不自动改。
3. **无人值守的定时自动升级。** 本功能仍然是人敲一条命令触发的。
4. **降级到任意历史版本。** 只保留一份 `$BIN.prev`，`rollback` 只能退一步。
5. **沙箱阶段验证 TUN 与系统路由相关的回归。** 派生配置删掉了 `tun`，这类问题只能在阶段 2/3
   被发现，靠回滚兜底。这是「不停现网」换来的，是自觉的取舍。
6. **引入任何新依赖**（`jq`、`bats`、brew 包都不行）。
7. **macOS 以外的平台。**

## 受影响的文件与接口

**`singbox.sh`**

| 位置 | 改动 |
|---|---|
| `cmd_update`（`1409-1447`） | 重写为四阶段 |
| 新增 `cmd_rollback` | `$BIN.prev` 换回 → `cmd_restart` → 阶段 3 验收 → 没有 `.prev` 时报错退出 |
| 新增内部 helper | `_sb_stage_prefix` / `_sb_derive_config` / `_sb_free_port` / `_sb_probe_socks` / `_sb_health`（存活+路由+端口） |
| 调度器（`1764` 附近） | `rollback) cmd_rollback ;;` |
| 帮助文本（`19` 与 `1697`） | 两处都要加 `rollback`，并更新 `update` 那一行的说明 |

复用而**不要重写**的既有 helper（都已确认存在）：`require_installed` `need_root` `acquire_lock`
`latest_version` `detect_arch` `mktmpd` `mktmp` `download` `running` `ask` `die` `step` `ok` `bad`
`warn` `info` `dim` `json_valid` `cmd_restart` `cmd_verify` `cmd_stop`。

**测试（新增）**

- `tests/update.test.sh` —— 状态机断言
- `tests/fixtures/bin/` —— PATH 前置的桩：`sing-box`（行为由 `SB_FAKE_*` 控制）、`sudo`（直接
  `exec "$@"`，另认 `-n true` 与 `-v`）、`curl`、`launchctl`
- `tests/run.sh` —— 遍历并运行 `tests/*.test.sh`

**`.claude/sdlc.json`**：`check.command` 改为 `./singbox-selfcheck.sh && ./tests/run.sh`。
现在是硬编码两条，再加第三条会一直手工维护下去。

**文档**：`docs/script-usage.md` 的 `update` 一节（`388-394`）、`README.md:142` 的命令表、
`README.md:164` 与 `:200`（顺带补上 `tests/`）。`CONTRIBUTING.md` 已经写了「改了自检规则要补
fixture」，这条对 `tests/` 同样适用，不必再改。

**契约**：单栈（纯 shell），不涉及跨栈契约，`contracts.files` 不需要动。

**文档源**：`.claude/sdlc.json` 已登记 `sing-box → /sagernet/sing-box` @ `1.13.14`
（本机内核 `1.13.18`）。实现时如需查 `check` 的退出码语义或 `cache_file` 字段行为，走
`sdlc-docs get sing-box "<问题>"`，不要凭印象。

## 待定问题

| 问题 | 现在按什么做 | 谁拍板 |
|---|---|---|
| GitHub release 是否提供 checksum 文件？**未核实** | 有就校验 sha256；没有则降级为「解压后 `sing-box version` 能跑且架构匹配」，并在输出里说明没有做完整性校验 | build 阶段实测 release 资产列表后自行确定 |
| 阶段 3 的重试轮数与间隔 | 暂定重试 1 次、间隔 5s | lzyMeta（可事后调） |
| 沙箱闲置端口的选取 | 暂定从 `10900` 起向上探测第一个没被占用的 | build 阶段自行确定 |
| 升级成功后是否自动跑 `cmd_rules` | **维持现状**：只打印提醒，不自动跑。`.srs` 重新下载会走网络，不该塞进升级流程 | lzyMeta |
| `$BIN.prev` 的磁盘占用（约 30-50MB） | 接受，不做清理策略 | lzyMeta |

## 验证

**可机械执行的部分**（进 `check.command`，离线、不需要 sudo、不碰真实系统）：

```bash
./tests/update.test.sh
```

做法：把 `tests/fixtures/bin/` 前置到 `PATH`，`--prefix` 指到 `$TMPDIR` 下的临时目录，
用环境变量驱动假 `sing-box` 的行为，逐条断言状态机：

| 分支 | 断言 |
|---|---|
| 一切正常 | 退出 0；`$BIN` 是新版本；`$BIN.prev` **存在**且是旧版本 |
| 阶段 1 沙箱 `check -c` 失败 | 退出非 0；**`$BIN` 一个字节都没被动过**；没有产生 `.prev` |
| 阶段 1 沙箱建链失败 | 同上——现网完全没被触碰 |
| 阶段 2 `check -c` 失败 | 回滚；`$BIN` 是旧版本；`.prev` 被清理 |
| 阶段 2 起不来 | 回滚（**这一条现在的实现拓不到，是本次的核心修复**） |
| 阶段 3 verify 两轮都失败 | 回滚；`$BIN` 是旧版本 |
| 阶段 3 verify 第一轮失败、第二轮通过 | **不回滚**，退出 0（防误判那条的正控） |
| 跨 minor 且非交互 | 不升级，退出 0（`ask` 默认 `n`） |
| `rollback` 有 `.prev` | 换回旧版本、重启、跑验收 |
| `rollback` 无 `.prev` | 报错退出非 0，不动任何东西 |

**不可机械化的部分**（真机手工，升级真实内核时走一遍）：

1. `singbox update` 全程，观察四个阶段的输出顺序与耗时
2. 升级后 `singbox verify` 五步全过
3. `singbox rollback`，确认换回旧版本且代理恢复可用
4. 断网状态下跑 `singbox update`，确认在阶段 0 就干净地失败，不留下半个状态

## 实现计划

### 待定问题的落地结论

| 问题 | 结论 | 依据 |
|---|---|---|
| release 有没有 checksum | **没有**。降级为「解压后 `version` 能跑 + `Environment:` 行的 `darwin/<arch>` 匹配」，并在输出里明说未做 sha256 | 实测 v1.14.0 的资产列表，无 `checksums.txt` / `.sha256` / `SHA256SUMS` |
| 沙箱闲置端口 | `python3` 从 `10900` 起 bind 探测，最多试 200 个 | `python3` 已是硬依赖，比 `lsof` 准且不要 sudo |
| 阶段 3 重试 | `VERIFY_RETRY_WAIT=5`，重试 1 轮 | spec 暂定值，照用 |

### 顺带修掉的两处（spec 没写，但不修就落不了地）

1. **`ask "升级到 X？"` 的默认值 `n` → `y`。** 原样下 `singbox -y update` 取默认 `n`，**永远不升级**（帮助文本里还把它当示例）。更要命的是外层闸门恒为 `n` 时，阶段 0 那道跨 minor 确认就是死代码。改成主确认默认 `y`、跨 minor 确认默认 `n`，两道闸门才各司其职。
2. **`cmd_verify` 的退出码。** 原样下只有第 1 步会 `return 1`，第 2/3/4/5 步打了 `✗` 照样返回 0——阶段 3 拿它当回滚判据，会把坏掉的升级判成成功。加 `VERIFY_BAD` 计数与 `vbad()`，末尾按计数返回。判据是 **`bad`（`✗`）算硬失败、`warn`（`!`）算软告警**，正好对上 spec 说的「一次抖动不该回滚」。

### 「五步全部算硬失败」的收窄解读（**已作废，见下**）

本次提交落地的判据是 **`bad`（`✗`）算硬失败、`warn`（`!`）算软告警**，比「决定」一节
写的「五步全部算硬失败」窄。当时列出的软分支有 5 处：第 2 步的 `ipinfo.io` 取不到、
第 3 步的未装 `dig`、第 4 步的 curl 不支持 http3 与 HTTP/3 仍可用、第 5 步的整步无断言
（`cip.cc` 取不到只 `info`、拿不到网关静默跳过）。

理由是：**这些分支多数不是「失败」而是「测不了」**，把测不了也算失败，每次 `singbox update`
都会在阶段 3 回滚。2026-09-04 由 lzyMeta 拍板维持现状。

⚠️ **这个结论已被 `docs/verify-hardening.md` 推翻并兑现，上面那张软分支表全部作废。**
推翻它的是三条：`dig` 本就是 macOS 自带、同目录还有 `host` / `dscacheutil`，第 3 步根本
不缺解析手段；第 4 步的 QUIC 不必依赖 curl 的编译选项，`python3` 发一个 QUIC 版本协商包
就能测；而「测不了就会回滚」这个后果可以拆开——**分档之后，收紧判定与不误回滚不再冲突**。
下面 190-197 行原先标注「另开一条」的第 5 步判据（国内出口 IP 应不等于 SOCKS 出口，
真机数据：SOCKS 出口 `<vps-socks-ip>` vs `cip.cc` 报的 `<home-cn-ip>` 上海电信），
也已由那份 spec 兑现。

### 现行判据：`cmd_verify` 的两档失败

判据只有一条：**回滚到旧内核能不能把它换回来**。

| 档 | 计数器 / helper | 哪些分支 | 退出码 | 阶段 3 的动作 |
|---|---|---|---|---|
| 链路档 | `VERIFY_BAD` / `vbad()` | 第 1 步 SOCKS 不通（立即 `return 1`）；第 2 步兜底取不到 IP、两个出口相同；第 4 步存在全局 IPv6 | `1` | 重试一轮，仍失败则回滚 |
| 策略档 | `VERIFY_POLICY_BAD` / `vpbad()` | 第 2 步 `ipinfo.io` 连取 3 次都没结果；第 3 步疑似污染、四级解析全废；第 4 步 QUIC 未被阻断；第 5 步国内出口等于 SOCKS 出口、三家参照站全挂、拿不到默认网关、网关连试 3 次不通 | `2` | **不回滚**，`warn` 后放行 |

两档都失败时返回 `1`，链路优先——链路都断了，策略上的结论没有参考价值。
`_sb_verify_rounds` 因此改为读退出码而非布尔：`0` 与 `2` 都返回 0，只有 `1` 才进重试与回滚。

**五步里不再有任何静默跳过。** 原先「测不了」与「测过了」在终端上长得一样（都不打 `✗`、
退出码都是 0），现在测不了本身就是一条打 `✗` 的结论，只是它落在策略档、不触发回滚。

### 落地的结构

`singbox.sh` 新增 helper：`_sb_free_port` / `_sb_port_listening` / `_sb_derive_config` / `_sb_stage_prefix` / `_sb_probe_socks` / `_sb_health` / `_sb_warn_deprecated` / `_sb_verify_rounds` / `_sb_rollback_to_prev`；`cmd_update` 重写为四阶段；新增 `cmd_rollback`；调度器与两处帮助文本跟上。

测试脚手架：`tests/run.sh`、`tests/update.test.sh`（10 条状态机断言）、`tests/fixtures/bin/`（`sudo` `curl` `launchctl` `pgrep` `netstat` `ifconfig` `dig` `ping` `sleep` 九个 PATH 桩）、`tests/fixtures/fake-sing-box`（假内核模板，版本号 `sed` 进去）。

三处值得记下的桩设计：

- **假内核按「装在哪」决定行为**（`$0` 是否等于 `$SB_FAKE_LIVE_BIN`）。阶段 1 与阶段 2 跑的是同一个二进制、同一份配置，只有位置不同——要让这两处能分别失败，判据只能是位置。
- **`sleep` 桩不能无条件立即返回。** `need_root` 会起一个 `while …; do sudo -n true; sleep 50; done &` 的保活循环，压到 0 就是个吃满 CPU 的忙循环。按时长分流：≥30s 走真 `sleep`，短的压到 0.05s。
- **`launchctl` 桩真的占住现网端口**，`_sb_health` 的「端口在听」才有东西可测；服务起不起得来由**此刻装在现网位的那个二进制的版本**决定，这正是「阶段 2 换了新内核之后起不来」要走的路径。

### 实现过程中发现的一个真 bug（不在 spec 里）

`_sb_health` 第一版写的是 `netstat -rn -f inet | grep -q utun`。`grep -q` 一命中就退出，`netstat` 吃 SIGPIPE 死掉，`set -o pipefail` 把那个 141 当成整条管道的退出码——**「路由在」被判成「路由没了」，于是回滚一次本来成功的升级**。撞不撞得上取决于调度时机，是偶发的；真机上的路由表比测试桩长得多，只会更容易撞上。改成先落变量再 `case` 匹配（跟 `cmd_status:940` 一个写法）。

这条是测试抓出来的：同一次运行里，阶段 2 报「没有 utun」、几秒后的回滚报「TUN 路由存在」。

### 真机配置暴露出的两个缺陷（spec 与首轮实现都漏了）

拿 `/usr/local/etc/sing-box/config.json`（真实在跑的那份）对派生逻辑做对照时发现的：

**① `experimental.clash_api` 是第四处会撞车的监听。** spec 只列了 `tun` / `mixed` / `cache_file` 三处，真实配置里还有 `clash_api.external_controller = "127.0.0.1:9090"`——现网实例占着它，沙箱实例起来就撞死在这个端口上，且与新内核好不好毫无关系。`external_ui: "monitor"` 还会在启动时去下载一份 UI。派生逻辑改为：**只保留一个被改到闲置端口的 `mixed`/`socks` inbound，其余 inbound 全丢**；`experimental` 里整块删掉 `clash_api`；`log.output` 若指向文件也改到临时目录。

`config/config.example.json` 这份模板当时**没有** `clash_api`，所以对着模板核对是看不出来的——
事后已把它补进模板（`external_ui` 用 `"ui"`，与 `cmd_uninstall` 清理残留时找的目录名一致），
这样下次拿模板核派生逻辑就能覆盖到这一处。

**② `tests/` 的现网端口写死 10808，撞上了本机正在跑的真 sing-box。** 桩的监听 bind 失败即死，而 `_sb_health` 的「端口在听」照样成立——**测试是被真实服务喂绿的**，不是被桩。这与本仓库 `tests/selfcheck.test.sh` 头部记的那次回归是同一类：一条不因违规而红的检查比没有检查更糟。修法两条：端口在 `setup` 里从 21800 / 21900 起动态探测；**桩起不来当场 `exit 1`**，不静默放过。

顺带把阶段 1 等待沙箱监听的窗口抽成 `SANDBOX_WAIT=40`（原为写死 15 次 ×1s）。真实配置有 21 个 `type: remote` 的 rule_set 且沙箱缓存是空的，冷启动要现下一遍——这正是评审时列为 UNVERIFIED SUSPICION 的那条。

### 验证

`./singbox-selfcheck.sh && ./tests/run.sh`，已进 `.claude/sdlc.json` 的 `check.command`。

断言 11（沙箱不与现网 `clash_api` 撞车）同样是先红后绿：修桩之后 **通过 7 / 失败 4**，红的内容点名 `沙箱实例没能起来（端口 10900 始终没有监听）`；删掉 `clash_api` 后转绿。

先写断言跑出红（**通过 2 / 失败 8**，红的内容点名 `升级到 1.13.19？ → 取默认（n）`，即上面第 1 条），再写实现跑出绿（**通过 18 / 失败 0**，退出码 0）。因为修掉的是时序相关的偶发 bug，绿连跑了 3 次确认稳定。

⚠️ 红的那一轮里 `rollback 无 .prev` 是**假绿**——「未知命令」同样非 0 退出且不动文件。已收紧为「必须点名 `.prev` 且不得出现『未知命令』」。

### 真机手工验证：已完成（2026-09-04，`1.13.18` → `1.14.0`，跨 minor）

spec「验证」一节的 4 条**全部通过**：

| 项 | 结果 |
|---|---|
| 1 · `update` 全程四阶段 | 两道确认按设计分别是 `[Y/n]` 与 `[y/N]`；阶段 1 沙箱 `check` 通过、建链拿到出口 IP；阶段 2 健康检查 4/4；阶段 3 第 1 轮即通过 |
| 2 · 升级后 `verify` | 五步全过；`rules` 21/21 均 200 |
| 3 · `rollback` | 换回 `1.13.18`、重启、验收通过；再 `update` 回到 `1.14.0` |
| 4 · 断网跑 `update` | 阶段 0 干净失败（「GitHub 与所有镜像均不可达」），`/usr/local/bin/` 下无 `.prev`、无残留 |

评审时留的两条 UNVERIFIED SUSPICION **均未出现**：`_sb_health` 紧跟 `cmd_restart` 的时间窗，在 4 次真实重启（2 次 update + 1 次 rollback + 1 次 restart）中全部一次通过；沙箱冷启动也两次都在窗口内起来。⚠️ 这是「未观察到」，不是「不可能」——两者都是竞态。

⚠️ **只有一处没验到**：spec 说「观察四个阶段的输出顺序与耗时」，输出里没有时间戳，**耗时那半没有数据**。顺序是对的。

### 真机输出暴露的第三个缺陷

`_sb_health` 原本拿整张路由表宽匹配 `utun`。真机上 `utun9527` 有 9 条路由，其中只有 `128.0/1` 那条是「接管了流量」的证据，而 `172.18.0.1 … UH utun9527` 只说明**接口建起来了**。接口在、`auto_route` 却没装上时，流量从 `en0` 裸奔，宽匹配会判成健康并接受这次升级——正是本功能存在的理由那种故障。

判据改为与 `cmd_status:940` 一致：先 `grep -E 'default|^0/1|^128\.0/1'` 过滤，再看 utun。新增断言 12 覆盖（`SB_FAKE_TUN_HOST_ONLY=1`）；顺带补上了此前一条断言都没有的 TUN 分支。

同时修正了阶段 1 那行提示——派生逻辑扩了之后它还在说「去掉 tun、mixed 改端口、cache_file 挪走」，少报了自己删掉 `clash_api` 这件事。
