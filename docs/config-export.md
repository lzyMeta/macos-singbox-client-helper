---
kind: spec
status: shipped
covers:
  - singbox.sh
  - tests/config-export.test.sh
  - docs/manual-config.md
appetite: {diffLines: 200, phases: 3}
---
# `config export <path>`：把当前生效的配置导出到自定义路径

## 问题

live 配置在 `/usr/local/etc/sing-box/config.json`（root 所有，0644），要拿走一份只能
`singbox config show > x.json` 或者手写 `cp`。两条路都有毛病：`config show` 走 `sudo cat`，
无谓地要一次 sudo；重定向会**先把目标清空再写**，敲错路径就把自己的旧备份覆盖了，且什么也不提示；
`cp` 出来的文件沿用 0644，一份含订阅地址与节点凭据的 JSON 就以世界可读落在了 `~/Downloads`。

还有一个只有本仓库知道的坑：`edit` 与 `config audit --apply` 改的是磁盘文件，进程要 `restart` 才吃到；
重启失败或人忘了重启时，磁盘上那份**不是**正在跑的那份。现在没有任何命令会告诉你这一点。

不做也不会坏——它是便利功能。但换机、给别人复现问题、给 `config audit --config` 喂一份快照，
每次都得手工凑这三件事（免 sudo、防覆盖、收权限），迟早有人把带凭据的文件权限敞开。

外部可抄的实现：没有。仓库内 `cmd_edit`（`singbox.sh:1996`）里 `sudo cp "$CFG" "$tmp"; chown; chmod`
那三行是同一动作的现成写法，直接复用它的形状。

## 决定

给 `cmd_config`（`singbox.sh:3323`）加一个 `export <path> [--force]` 分支：把 `$CFG` **逐字节**复制到
`<path>`，不解析、不改写、不脱敏。目标已存在则拒绝，`--force` 才覆盖；目标是目录或父目录不存在则拒绝
（不学 `cp` 往目录里补文件名——省一个分支，也省一条「到底写到了哪」的猜测）。导出物 owner 是调用者
（走 sudo 时取 `$SUDO_UID:$SUDO_GID`），mode **0600**——它带凭据。读 `$CFG` 不需要 root（0644），
所以整条命令**不 `need_root`、不 `acquire_lock`**，只 `require_installed`；`-n` 走仓库惯例「动手前打印计划
再 return」。复制完 `cmp` 一次源与目标，不等就 die 并删掉半截文件。

「当前生效」以**磁盘 `$CFG` 为准**——launchd 只会从它起进程，磁盘是唯一事实源。但如果 sing-box 正在跑且
进程启动时刻早于 `$CFG` 的 mtime（`ps -o etime=` 反推启动时间，对 `stat -f %m`；macOS `ps` 没有 `etimes`），
stderr `warn` 一句「磁盘配置比运行中的进程新，导出的是磁盘版；要导出进程正在用的那版，先 `restart`」。
只警告，不阻断——「先导出再重启」是合理顺序，不能卡死它。

因此什么会变差：`config` 又多一个子命令，help 那三行变四行；导出物是 0600，用户想拿去分享得自己 `chmod`，
而分享之前本来就该先脱敏——这是故意的摩擦。

**备选与否决**
- 默认脱敏、`--raw` 才原样 —— 「哪些键算凭据」要跟 sing-box 每个协议的字段对表维护，漏一个就是假安全；
  且脱敏后的文件不能直接回灌，不再是「当前所应用的配置」。脱敏留作独立立项。
- 目标存在时交互 `ask`，`-y` 免问 —— 脚本场景要多记一个全局旗标；`--force` 与 `--apply`/`--deep` 同款，
  局部、可 grep。
- 进程比文件旧时拒绝导出 —— 会卡死「先导出再重启」这条最常见的顺序。
- 顶层子命令 `export` —— 备份/恢复/审查全在 `config` 下，它是同一族；顶层多一个词要改 README 命令表、
  分发表、docs 测试三处，换不来任何清晰度。
- `config show` 加 `--out` —— `show` 的语义是「打到终端」，塞文件语义进去要处理 stdout 与文件的互斥。

<details><summary>面试原始问答</summary>

| # | 问 | 答 |
|---|---|---|
| 1 | 导出的配置里含真实订阅地址与节点凭据。默认行为选哪种？ | 默认原样导出（不提供脱敏旗标，脱敏留给以后单独立项） |
| 2 | 目标路径已存在文件时怎么办？ | 拒绝，需 `--force` 才覆盖 |
| 3 | 「当前所应用」以谁为准？磁盘 `$CFG` 可能比正在跑的进程新。 | 以磁盘 `$CFG` 为准，检测到进程比文件旧时 warn 一句，不阻断 |
| 4 | appetite（天花板 diffLines=400、phases=6；近 50 提交 p50=29、p90=415） | diffLines 200，phases 3 |

</details>

## 不在范围内

- **脱敏 / 去凭据**：不提供 `--redact`，不改写任何键。要分享请自己处理。
- **导出 `$CFG` 以外的东西**：`prefs`、`dns-backup`、`config.json.*.bak`、内核二进制、plist 都不导。不做「打包一整套」。
- **导入 / 回灌**：反方向已有 `config restore`（只认 `$CFG.*.bak`）与 `install --config`，不新增 `config import`。
- **格式转换**：不 `jq` 重排、不压缩、不转 YAML；输出与源 `cmp` 全等。
- **写到 stdout**（`-` 作路径）：`config show` 已经干这个。
- **目标是目录时自动补 `config.json`**：拒绝并提示，让人写全路径。
- **远程目标**（`scp://`、iCloud 特殊处理）：路径只当本地路径。

## 受影响的文件与接口

（本表行号只在 build 期间有效；shipped 后不保证，以文件名为准。）

| 文件 | 位置 | 改法 |
|---|---|---|
| `singbox.sh` | `cmd_config` `singbox.sh:3323`，`case` 里 `audit)` 之前 | 新增 `export)` 分支：解析 `<path>` 与 `--force`（每个 `shift 2` 前查 `${2:-}`），存在性/目录/父目录三查，`-n` 早退，`cp` → `chown` → `chmod 600` → `cmp`，进程陈旧性 warn |
| `singbox.sh` | 文件头注释 `singbox.sh:19` 与 `cmd_help` `singbox.sh:4345-4347` | `config <sub>` 一行加 `export <path> [--force]` |
| `singbox.sh` | `cmd_config` 末尾 `*) die "config: 未知子命令 …"` | 错误提示的子命令清单加 `export` |
| `tests/config-export.test.sh` | 新建 | 用 `--prefix <mktemp -d>` 造假 `$CFG`，覆盖下面每条 AC；进程陈旧性用 `PATH` 前置的假 `pgrep`/`ps` 桩 |
| `tests/docs.test.sh` | 「参数解析」那一节 | `config export` 的 `--force` 与手册对表（沿用 `config audit` 旗标核对的写法） |
| `docs/manual-config.md` | §2「备份与回退」`docs/manual-config.md:33` 之后 | 加 `singbox config export <path> [--force]` 一行与 0600 / 陈旧性警告两句 |
| `README.md` | `README.md:89` 命令表 | 不改——`config` 已在表里，子命令不展开 |

不跨栈，无契约文件。

## 待定问题

- 走 sudo 时导出物归 `$SUDO_UID:$SUDO_GID`，不走 sudo 时归 `$(id -u):$(id -g)`——build 时确认 macOS 的 `sudo` 确实导出这两个变量（`SUDO_UID` 是 sudo 标准行为，但 `chown` 要接受数字 uid:gid 形式） —— 已定
- `cmp` 失败后删半截文件：目标原本存在且带 `--force` 的情形，删掉等于把用户的旧文件也丢了。build 时选「先写到同目录的临时名再 `mv`」还是「失败就留半截并明说」 —— 已定（2026-09-14 用户选「临时名再 `mv`」：`<dir>/.<name>.tmp.$$`，chown/chmod/cmp 都在临时文件上做，全过才 `mv -f`，失败只删临时文件）
- 进程陈旧性判据只比 `$CFG` 的 mtime 与进程启动时间；`audit --apply` 走 `sudo cp` 会刷新 mtime，`restore` 也会——都符合预期。但 `touch` 也会触发误警告，接受 —— 已定

## 验证

### 验收条件
- AC1 ★ `singbox --prefix <tmp> config export <tmp>/out.json` 退出 0，`cmp <tmp>/etc/sing-box/config.json <tmp>/out.json` 全等。反例：把复制源改成 `$CFG.bak` 或往输出多写一个换行，`cmp` 红。
- AC2 目标已存在且无 `--force`：退出非 0、stderr 含「已存在」、目标内容与执行前逐字节不变；加 `--force` 后覆盖成功。反例：删掉存在性检查，「目标不变」断言红；把 `--force` 解析漏掉，第二次调用红。
- AC3 不给路径、或路径是已存在目录、或父目录不存在：退出非 0 且 stderr 带用法/原因，不创建任何文件。反例：让 `${2:-}` 默认成空串直接进 `cp`，退出码是 `cp` 的而非 `die` 的、提示语断言红。
- AC4 导出物 mode 是 `0600`（`stat -f %Lp` = `600`），owner 是调用者的 uid。反例：漏掉 `chmod`，继承源的 `644`，红。
  [revised] build 时实测：真正的守卫是 `( umask 077; cp )`——临时文件出生即 0600，不留「cp 完、chmod 前」的 0644 窗口；`chmod 600` 只是保险，单删它测试仍绿。反例改为「去掉 umask 且删 chmod」才红。
- AC5 `-n config export <path>` 打印计划、退出 0、目标不出现。反例：把早退点挪到 `cp` 之后，目标出现，红。
- AC6 假 `pgrep` 报有进程、假 `ps -o etime=` 报进程已跑 1 小时、`$CFG` mtime 是现在：stderr 含「比运行中的进程新」且退出仍为 0；进程比文件新、或 `pgrep` 报没进程时不出现该行。反例：把比较方向反过来，前者不警告、后者误警告，两条断言各红一条。
- AC7 `docs.test.sh` 能在 `cmd_help` 与 `docs/manual-config.md` 里都找到 `config export`。反例：删掉手册那一行，红。

### 检查命令
```bash
./singbox-selfcheck.sh && ./tests/run.sh
```

## 实现计划

2026-09-14 build，Claude Code 实现。先写测试看红（`config: 未知子命令 export`，13/13 红，退出 1；`docs.test.sh` 退出 1），再实现看绿。

1. `tests/config-export.test.sh`（新建）：仿 `verify.test.sh` 骨架；`pgrep` 用 `tests/fixtures/bin`，假 `ps` 在测试里自造（读 `SB_FAKE_STATE/etime`，否则透传 `/bin/ps`）。AC1–AC6 共 13 条断言，含 `dd-hh:mm:ss` 形态一条。
2. `tests/docs.test.sh` §2：旗标抓取循环 `for sub in audit export`，从 `config <sub>: 未知参数 $1（…）` die 文案抓；新增 AC7 断言（help 含 `export <path>`、手册含 `singbox config export`）。
3. `singbox.sh`：`_cfg_export_stale_warn`（`ps -o etime=` 解析为秒反推启动时刻，对 `stat -f %m`）；`cmd_config` 的 `export)` 分支放在 `audit)` 之前；头注释、`cmd_help`、`*)` die 清单加 `export`。
4. `docs/manual-config.md` §2 加命令行与三句说明；`README.md` §5 结构树加 `config-export.test.sh`；`CLAUDE.md` 测试清单加一项、计数由 `sdlc-doc gen --write` 重算。

变异验证：AC6 比较方向反转 → 3 条红；AC4 单删 `chmod` 不红（见 AC4 `[revised]`）。
踩坑一条：`"$e_dst（0600）"` 在 bash 3.2 报 `unbound variable`，必须 `${e_dst}`——CLAUDE.md 已有记载。
