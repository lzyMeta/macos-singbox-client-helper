# macos-singbox-client-helper

管理 macOS 上 sing-box 内核的 shell 脚本。单文件 `singbox.sh`（约 110KB，`set -uo pipefail`）是全部实现，
`singbox-selfcheck.sh` 是它的静态自检。没有 CI、没有包管理器、没有测试框架。

## 验收

```
./singbox-selfcheck.sh && ./tests/run.sh
```

前半段是 `singbox.sh` 的静态自检（13 项），后半段是 `tests/` 下的十个测试文件：
`cli`（参数解析）、`selfcheck`（自检项本身）、`install`（装 `singbox` 命令）、
`selfupdate`（`update` 阶段 S 的脚本自更新）、`update`（内核升级状态机与 `rollback`）、
`logs`（日志体积与截断）、`platform`（架构判定）、`verify`（两档退出码）、
`config-audit`（四路发现层、迁移表、`--apply` 三条规则与四道验收）、
`doctor`（TUN 路由判读：`_tun_route_state` 三处共用）。

**TUN 路由的判据是两半都要**：上半 `128.0/1`，下半 `0/1` 或 sing-tun v0.9 起的七段
`1/8 2/7 4/6 8/5 16/4 32/3 64/2`（避开 `0.0.0.0/8`）。只认 `0/1` 会把真机形状误报成「未接管」，
只认 `128.0/1` 会把「只有上半」这种真故障判成健康。假 `netstat` 桩默认吐七段形状。

`tests/run.sh` 给每个测试文件一把独立的锁（`SB_LOCKDIR`，`mktemp -d` 下）；`singbox.sh` 的
`LOCKDIR` 默认 `/tmp/.singbox-sh.lock`，只在测试里用这个变量改。以前测试与 live 的 `singbox`
命令共用一把锁，teardown 还会顺手删掉 live 的锁——那是连跑偶发红的嫌疑来源。

`selfcheck.test.sh` 验证那 13 项**真的在检查**。两种坏法都踩过，且都不会自己暴露：

- **恒红**：有 2 项用了 GNU 专有的 `grep -P`，在 BSD grep 上恒报 `invalid option`——
  既抓不到违规，也永远不会绿。
- **恒绿**：嵌套函数那一项的内层正则写死了「恰好 2 个空格」缩进，于是文件里
  6 空格缩进的嵌套定义从它旁边大摇大摆走过去，那一项永远报 OK。

所以每一项在 `tests/fixtures/` 里都必须同时有**会被抓到**和**不该被抓到**的样本。

Stop 闸门开着（`check.stopHook = "on-edit"`）：改完代码要停下时会自动跑一次，红了停不下来，
连续两次修不好则放行。改 `**/*.md` / `docs/**` / `.claude/**` 不触发。

修 `singbox-selfcheck.sh` 本身时它是实现文件而不是测试文件——被 `fix.testGlobs` 锁住的是
`tests/**`。

## 运行环境的硬约束

- 目标是 macOS 自带的 **bash 3.2.57**，不是 bash 4+：没有 `declare -A`、`${x^^}`、`mapfile`。
- 工具链是 **BSD 不是 GNU**：没有 `sed -i `（带空格）、`readlink -f`、`date -d`、`head -n -N`、`grep -oP`。
- bash 3.2 解析 `$VAR中文` 会出错，变量后紧跟全角字符必须写 `${VAR}中文`。
- **判 CPU 架构不能用 `uname -m`**：它报的是当前进程的架构，Rosetta 翻译下会说 `x86_64`。
  硬件判据是 `sysctl -n hw.optional.arm64`（Intel 上这个键不存在，sysctl 退出 1）；
  `sysctl -n sysctl.proc_translated` = 1 表示当前 shell 正被翻译。
- `shift 2` 在参数不够时**返回 1 且不消耗任何参数**，`while [ $# -gt 0 ]` 的解析循环会死转。
  每个 `shift 2` 之前都要 `[ -n "${2:-}" ] || die`。
- 同一条 `local` 里引用不到前面刚声明的变量：`local a=x b="$a"` 里 `$a` 取的是外层作用域，
  多半是空，而且**不报错**。要分成两条语句写。

## 这台机器上有 live sing-box

`/usr/local/etc/sing-box/config.json` 是用户正在用的配置（root 所有）。`./singbox.sh` 的
install/uninstall/start/stop/restart/edit 会真的动 launchctl、路由表和 `/usr/local`，已 deny，要试人自己跑。

`install` 现在还会把脚本自己装到 `/usr/local/bin/singbox`，`update` 的阶段 S 会替换它 ——
同一条 deny 覆盖这两件事。`tests/install.test.sh` 故意在第 5/8 步中止，因为第 7/8 步的
`$PLIST` 路径写死在 `/Library/LaunchDaemons`，**不跟随 `--prefix`**。

## 不进仓库的文件

`.gitignore` 点名的 `config.json`、`sing-box-client-config.json`、`prefs`、`dns-backup` 含真实订阅地址与节点凭据。
`config/config.example.json` 才是可以读改的模板。
