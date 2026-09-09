# singbox 命令的自动安装与脚本自更新

## 问题

现在有两件事是脚本自己做得了、却推给了用户手工做的。

**一、把命令装进 PATH 是一段 README 里的手抄命令。** `README.md` 2.5 节写着：

```bash
mkdir -p ~/bin && cp singbox.sh ~/bin/singbox && chmod +x ~/bin/singbox
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

`install` 已经在 `need_root` 之后往 `$PREFIX/bin` 里放内核了（`singbox.sh:809` 起的 1/7 步），
就差把自己一并放进去——同一个目录、同一个 sudo 票据、同一个 `--prefix`。让用户去抄两行 shell、
去改 `~/.zshrc`，还引入了一个 README 里根本没说的分叉：`cp` 出来的那一份从此与仓库副本各活各的，
仓库里改了脚本，`singbox` 命令还是老的，而没有任何东西会告诉你这件事。

**二、`update` 只升内核，脚本本体永远停在装机那天的版本。** 而这个仓库最近五个 commit
修的全是脚本自己的严重缺陷——架构判断在 Rosetta 下装错内核（f19b4eb）、日志涨到失控没人管
（ea52709）、一次全命令审计修了 5 处（327fbd1）。这些修复对已经装好的用户等于不存在：
他手上那份 `singbox` 不会自己变新，而他唯一会跑的升级命令 `update` 一个字节都不碰它。
换句话说，**修得越多，装机用户与仓库的差距越大**，而这个差距在终端上完全不可见。

不做的话，这两件事会以同一种方式坏：用户以为自己在用最新的工具，实际在用一份来历不明、
永不更新、且与仓库任何一次修复都无关的副本。

## 决定

`install` 在装完内核之后，把当前正在执行的这份脚本安装到 `$PREFIX/bin/singbox`（默认
`/usr/local/bin/singbox`，跟随 `--prefix`），权限 0755，已存在则先把旧的存成
`$PREFIX/bin/singbox.prev` 再覆盖——与内核 `$BIN` / `$BIN.prev` 的退路语义完全对称。
选这个位置而不是 `~/bin`，是因为它已经在所有 shell 的默认 PATH 里：**不用碰 `~/.zshrc`，
自动化才算真的做完了**；而 `install` 本来就已经 `need_root`，不多要一次权限。

`update` 在现有三阶段之前插入**阶段 S（脚本）**：查自家仓库
`lzyMeta/macos-singbox-client-helper` 的 latest release，比对 `singbox.sh` 里的 `VERSION`，
远端更新则下载 asset `singbox.sh`（走与内核完全相同的 `download()` / 镜像 / sha256 校验路径）、
`bash -n` 过一遍、原子替换 `$LAUNCHER`，然后 `exec` 新脚本继续跑阶段 0–3。
**顺序是「先脚本后内核」**：这样内核升级用的永远是最新的升级逻辑——过去五个 commit 里，
出问题的恰恰是升级逻辑本身而不是内核。

取不到脚本新版（无 release、GitHub 与所有镜像均不可达）时 `warn` 一句然后照升内核：
脚本更新不该有权阻断用户真正要的那件事，何况内核升级自带沙箱与回滚。

`rollback` 一并退启动器（`$LAUNCHER.prev` → `$LAUNCHER`），`uninstall` 在整个流程的最后
一条语句删掉 `$LAUNCHER` 与 `$LAUNCHER.prev`——装的时候是脚本自动放进去的，卸载时就该自动清掉。

发布侧补一个 `.github/workflows/release.yml`：push `v*` tag 时校验 tag 与脚本里的
`VERSION` 一致，然后建 release 并把 `singbox.sh` 传成 asset。**tag = `v$VERSION`、
asset 名 = `singbox.sh`** 是脚本自更新与发布流程之间唯一的契约，两边都要照着它写。

### 承重的实现约束

这几条不是风格问题，写错了会以「静默失效」或「把用户的命令弄坏」的形式暴露：

1. **替换 `$LAUNCHER` 必须用 `mv`（rename）而不是 `cp` / `install` 直接覆盖。**
   bash 是**边执行边按偏移量读脚本文件**的。`cp` 覆盖的是同一个 inode，正在跑的这个进程
   下一次读取会读到新文件的字节流、落在错误的偏移上——症状是执行到一半冒出莫名其妙的语法错误，
   且只在「脚本更新自己」这一条路径上出现。`mv` 换的是目录项，旧 inode 被 unlink 但仍被打开着，
   当前进程读的还是那一份完整的旧内容。同理，`uninstall` 里的 `sudo rm -f "$LAUNCHER"`
   是安全的（unlink 不影响已打开的 fd）。
   → 为此给 `singbox-selfcheck.sh` 加**第 13 项**：禁止对 `$LAUNCHER` 用 `cp` / `install`
   直接覆盖。fixtures 里同时放会被抓到与不该被抓到的样本（`mv` 到 `$LAUNCHER` 不该报）。

2. **re-exec 的开关走环境变量 `SB_SELF_UPDATED=1`，不走命令行参数。**
   顶层 dispatch（`singbox.sh:2742` 附近）对未知参数一律 `die`。用 `--skip-self` 这种 flag
   意味着**旧脚本 exec 新脚本时，新脚本必须认识旧脚本传的每一个参数**——哪天参数改名，
   升级路径当场断在「未知参数」上，而这条路径恰恰是用来修 bug 的。未知环境变量不会让谁 die。

3. **`exec` 保留 PID，锁会自己把自己锁死。** `acquire_lock`（`singbox.sh:87` 起）在
   `LOCKDIR` 已存在时读 `LOCKDIR/pid` 并 `kill -0` 判活；exec 之后 PID 不变，于是新进程
   判定「另一个实例正在运行（PID 就是我自己）」，等 3 轮然后 `die`——而那时脚本已经换过了。
   → 把 `LOCK_HELD=0`（`singbox.sh:89` 附近）改成 `LOCK_HELD="${SB_LOCK_INHERIT:-0}"`，
   exec 时带上 `SB_LOCK_INHERIT=1`。锁文件里存的 PID 在 exec 后依然是对的，不必删了重建，
   也就没有竞态窗口。

4. **`exec` 不触发 EXIT trap，`TMPFILES` 里的临时目录会泄漏。** 阶段 S 下载用的 `mktmpd`
   目录必须在 exec 之前显式清掉。`SUDO_KEEPALIVE_PID` 同理会丢：那个后台循环的条件是
   `kill -0 $$`，PID 没变所以它继续活着、票据继续续期（这是好事），但新进程不知道它存在，
   会再起一个。多一个循环无害且会随进程退出自终，但要在代码里写明白，别让下一个人以为是 bug。

5. **不能用 `sort -V` 比较版本**——`singbox-selfcheck.sh` 第 4 项（GNU 专有命令）直接禁掉它。
   手写 `ver_gt a b`：按 `.` 切三段做数值比较。**只有远端严格大于本地才升**，
   相等或更小一律不动（防止 release 被回退时把用户的脚本降级）。

6. **`install` 时若跑的是仓库副本（`./singbox.sh`），阶段 S 之外的语义要说清楚。**
   `update` 的阶段 S 更新的对象永远是 `$LAUNCHER`。如果当前进程不是从 `$LAUNCHER` 启动的
   （比较 `cd "$(dirname "$0")" && pwd` 得到的实路径，`readlink -f` 在 macOS 上不存在、
   也被自检禁了），就只更新 `$LAUNCHER`、`warn` 说明「你跑的是仓库副本，已更新的是
   `/usr/local/bin/singbox`」，**并且不 re-exec**——继续用另一份文件跑下去只会让人搞不清
   到底是谁在执行。`$LAUNCHER` 根本不存在时（老用户、从未装过），阶段 S 直接把最新版装进去。

## 不在范围内

- **不改 `~/.zshrc` 或任何 shell rc 文件。** 选 `$PREFIX/bin` 的全部理由就是不必碰它。
  用户若自定了 `--prefix` 到一个不在 PATH 的目录，脚本只提示一句，不代他改环境。
- **不做 `~/bin` 兼容与迁移。** 已经手工 `cp` 到 `~/bin/singbox` 的旧用户，新 `install`
  不会去找它、不会删它、也不会警告它——那需要在未知位置扫描一个同名文件，代价与收益不成比例。
  README 的 2.5 节改写时直接说明「旧的 `~/bin/singbox` 可以自行删掉」。
- **CI 上不跑 `./singbox-selfcheck.sh && ./tests/run.sh`。** release workflow 只做
  tag/VERSION 一致性校验与建 release。`tests/` 依赖 PATH 桩、python3 和 bash 3.2 的具体行为，
  从没在 GitHub macOS runner 上验证过；把它塞进发布闸门，等于让「能不能发版」取决于一件
  从未测过的事。想上 CI 是另一个独立改动。
- **不做脚本的签名或 GPG 校验。** 沿用内核那套 GitHub API asset digest 的 sha256，
  可信度边界与 `asset_digest()` 注释里写的一模一样：挡传输损坏与单镜像投毒，不是签名。
- **不做自动升级 / 定时检查 / 启动时提示新版。** 只有用户显式跑 `update` 才检查脚本更新。
- **不改内核升级的三阶段逻辑。** 阶段 0–3 一个字节不动，阶段 S 只在它前面插入。
- **不给 `install` 加 `--no-launcher` 之类的开关。** 装启动器是 `install` 的一部分，
  不是可选项；多一个参数就要多一条分支和一组测试。

## 受影响的文件与接口

**`singbox.sh`**（修改）

| 位置 | 改动 |
|---|---|
| 头部用法注释（第 3–35 行） | `update` 那行改成「升级脚本与内核」；补 `SB_SELF_UPDATED` / `SB_LOCK_INHERIT` 说明 |
| 全局常量（`:38`–`:75`） | 新增 `SELF_REPO="${SB_SELF_REPO:-lzyMeta/macos-singbox-client-helper}"`、`GH_SELF_API`、`GH_SELF_DL`、`LAUNCHER="$PREFIX/bin/singbox"` |
| `--prefix` 解析（`:2724`） | 那一行已经重算 `BIN`/`ETC`/`CFG`，把 `LAUNCHER` 一并加进去——漏了它就会出现「内核装进 `/opt`、命令装进 `/usr/local`」 |
| `LOCK_HELD=0`（`:89`） | 改为 `LOCK_HELD="${SB_LOCK_INHERIT:-0}"` |
| `latest_version()`（`:445`） | 加可选参数 `[api_url]`，默认 `$GH_API`，供自家 repo 复用 |
| `asset_digest()`（`:476`） | 加可选第三参数 `[api_repo]`，默认 `$GH_API_REPO`。⚠️ 别并进同一条 `local`（函数里那段注释讲的就是这个坑） |
| 新增 `ver_gt()` | 纯 bash 3.2 的三段数值比较，无 `sort -V` |
| 新增 `_install_launcher()` | 写临时文件 → `bash -n` → `chmod 755` → 旧的 `mv` 成 `.prev` → `sudo mv -f` 就位。支持 `DRY` |
| 新增 `_self_update()` | 阶段 S 全部逻辑，返回值不影响内核阶段 |
| `cmd_install()`（`:745`） | 内核那步之后插入新的 `2/8　安装 singbox 命令`，`0/7`–`7/7` 全部重编号为 `0/8`–`8/8` |
| `cmd_update()`（`:2223`） | 开头（`require_installed` 之后）插入阶段 S；`SB_SELF_UPDATED=1` 时整段跳过；`-n` 时打印将要做什么并计入现有的 dry-run 早退分支 |
| `cmd_rollback()`（`:2359`） | `$LAUNCHER.prev` 存在则一并退回；不存在只退内核并说明 |
| `cmd_uninstall()`（`:2550`） | 函数最后一条语句删 `$LAUNCHER` 与 `$LAUNCHER.prev` |
| `cmd_help()` | 同步 |

**`singbox-selfcheck.sh`**（修改）：新增第 13 项——禁止 `cp` / `install` 直接覆盖 `$LAUNCHER`。
注意它自己是**实现文件**不是测试文件（`fix.testGlobs` 锁的是 `tests/**`）。

**`.github/workflows/release.yml`**（新建）：`on: push: tags: ['v*']`，
`permissions: contents: write`，校验 `git describe` 的 tag 等于 `v$(sed -n 's/^VERSION="\(.*\)"/\1/p' singbox.sh)`，
不等就退非零；通过则 `gh release create "$TAG" singbox.sh`。

**测试**（新建 / 修改）

- `tests/selfupdate.test.sh`（新建）——阶段 S 状态机
- `tests/install.test.sh`（新建）——启动器安装
- `tests/update.test.sh`（修改）——`rollback` 一并退启动器
- `tests/selfcheck.test.sh`（修改）——第 13 项的正反样本
- `tests/fixtures/bad-cp-launcher.sh` + 对应的 good 样本（新建）
- `tests/fixtures/bin/curl`（修改）——加自家 repo 的 release API 与 asset 两个分支（详见「待定问题」末条）

**文档**

- `README.md`：2.1 节加 curl bootstrap（`curl -fsSLO .../releases/latest/download/singbox.sh`）；
  2.5 节重写成「install 已自动完成」；命令表里 `update` 一行；自检项数 12 → 13；安装七步 → 八步
- `CLAUDE.md`：验收段落里的「12 项」→ 13 项
- `docs/safe-update.md`：升级流程补上阶段 S

**不进 `.claude/sdlc.json` 的 `contracts.files`**：这不是跨栈改动，
tag/asset 命名的约定分散在 `singbox.sh` 与 `release.yml` 两处，没有单独的契约文件可锁。

## 待定问题

**只有一条需要人拍板，且它在 build 之后：**

- **首个 release 由谁发、发什么版本号？** workflow 只在有 tag 时才动，而现在仓库一个 tag 都没有。
  实现方在本次改动里把 `VERSION` bump 到 `1.2.0`；**推 `v1.2.0` 这个 tag 由 lzyMeta（用户本人）
  手工做**，实现方不代跑 `git push --tags`。在那之前阶段 S 永远走「取不到新版 → warn → 照升内核」，
  这条路径本身有测试覆盖（验证节第 8 条），所以不阻塞 build 与验收。
  ⚠️ 先有鸡先有蛋：`v1.2.0` 里那份 `singbox.sh` 是第一份**带**阶段 S 的脚本，
  而已装机用户手上那份**没有**阶段 S，拿不到它——他们必须手工重装一次（README 的 curl bootstrap
  就是给这批人的）。自更新从 `v1.2.1` 起才真正闭环。**这一点必须写进 release notes。**

以下三条原本挂在这里，现已定案，实现方照做即可：

- **`SELF_REPO` 写死但可被 `SB_SELF_REPO` 覆盖。** 默认 `lzyMeta/macos-singbox-client-helper`，
  加一个环境变量的成本是一行，收益有两处：fork 的人能指到自己的 fork；测试能把阶段 S 指向假 repo
  而不必依赖 URL 里的仓库名匹配。写进头部注释。
- **`--prefix` 与已装启动器不一致：不记进 `$PREFS`，只 warn。** `LAUNCHER` 在
  `singbox.sh:2724` 那行随 `BIN`/`ETC`/`CFG` 一起重新赋值即可。不把 prefix 记进 prefs 是因为
  `SB_PREFIX` 环境变量已经是一条覆盖路径，再加一条持久化的会造出「prefs 说 `/opt`、
  用户这次想装 `/usr/local`」的新歧义——为一个边缘场景引入一个说不清优先级的三方冲突不划算。
  `update` 时 `$LAUNCHER` 不存在就 warn 一句「启动器不在 ${LAUNCHER}，已按当前 --prefix 装入」。
- **curl 桩不需要支持 302，需要的是两个新分支。** 已核对 `tests/fixtures/bin/curl`：
  它按 URL 里的 `SagerNet/sing-box` 路径匹配，自家 repo 的请求会落进 `*) _emit ""` 兜底，
  于是阶段 S 除了「取不到新版」那条路什么都测不了。要加的是
  `*api.github.com/repos/*/macos-singbox-client-helper/releases/latest*`（吐 `tag_name`，
  受 `SB_FAKE_SELF_LATEST` 控制）与 `*/releases/download/v*/singbox.sh`（吐一份脚本内容，
  受 `SB_FAKE_SELF_SCRIPT` 控制）两个分支，digest 沿用现有「由文件实算」的写法。
  302 完全不涉及：脚本内部下载走的是带版本号的固定 URL（`$GH_SELF_DL/v<ver>/singbox.sh`），
  只有 README 里给人手工用的 `releases/latest/download/...` 会 302，而那条不进代码路径。
  桩里 `[ "$head_only" = 1 ] && exit 0` 那行保持不动。

## 验证

```bash
./singbox-selfcheck.sh && ./tests/run.sh
```

这条命令必须绿。除现有 12 项自检 + 四个测试文件外，下列断言是本次改动的验收标准，
全部离线、不要 sudo（`tests/fixtures/bin` 前置到 PATH）、`--prefix` 指向临时目录：

**`tests/install.test.sh`**

1. `install` 之后 `$PREFIX/bin/singbox` 存在、可执行（0755）、内容与源脚本逐字节相同
2. 目标位置已有**不同内容**的文件 → 旧内容出现在 `$PREFIX/bin/singbox.prev`，新的就位
3. 目标位置已有**相同内容**的文件 → 仍然就位，且不报错
4. `-n install` 不创建 `$PREFIX/bin/singbox`，但输出里有 `[dry-run]` 那一行

**`tests/selfupdate.test.sh`**

5. 远端 `VERSION` > 本地 → 启动器被换成远端内容、旧的进 `.prev`，且新进程确实被 exec
   （桩脚本在被执行时写一个标记文件，断言 `SB_SELF_UPDATED=1` 与 `SB_LOCK_INHERIT=1` 都传到了）
6. 远端 == 本地 → 启动器 sha256 不变，直接进阶段 0
7. 远端 < 本地 → **不降级**，sha256 不变
8. 取不到远端版本（curl 桩返回失败）→ 有 warn，且内核阶段照跑、退出码不受影响
9. 下到的脚本 `bash -n` 不过（桩返回一段坏语法）→ **不替换**，原文件 sha256 不变
10. `SB_SELF_UPDATED=1` 时阶段 S 整个跳过（防 exec 死循环）
11. `$LAUNCHER` 不存在 → 装进去，且不 re-exec
12. 当前进程不是从 `$LAUNCHER` 启动 → 更新 `$LAUNCHER`、有 warn、不 re-exec

**`tests/update.test.sh`（扩充）**

13. `rollback` 同时把内核与启动器退回 `.prev`
14. 只有内核有 `.prev`、启动器没有 → 只退内核，输出里说明启动器没有退路

**`tests/selfcheck.test.sh`（扩充）**

15. 第 13 项对 `tests/fixtures/bad-cp-launcher.sh` 报错（不会恒绿）
16. 第 13 项对 good 样本（`mv` 到 `$LAUNCHER`）不报（不会恒红）

**`release.yml` 的验证不进 `run.sh`**，手工核对两条即可，写进 PR 描述：
tag 与 `VERSION` 一致时能建出带 `singbox.sh` asset 的 release；
故意推一个不一致的 tag 时 workflow 红。

## 实现计划

`sdlc-check --scope` 对全部 14 个文件报 `verdict=warn`（单栈但文件多），因此拆成三个
单元，每个单元自己就跑绿 `./singbox-selfcheck.sh && ./tests/run.sh` 并单独落一个 commit。

**单元 A — 启动器的安装与清理**（commit `6eb59ad`）
`LAUNCHER` 常量 + `--prefix` 重算、`_install_launcher()`、`install` 插入 `2/8` 并把
`0/7`–`7/7` 重编号、`rollback` 退启动器、`uninstall` 末尾清理；自检第 13 项与正反
fixture；`tests/install.test.sh`（验收 1–4）、`selfcheck.test.sh`（15–16）、
`update.test.sh`（13–14）。

**单元 B — `update` 阶段 S**（commit `a329f06`）
`LOCK_HELD` 读 `SB_LOCK_INHERIT`、自更新常量、`latest_version()` / `asset_digest()`
参数化、`ver_gt()`、`_self_update()`、`cmd_update` 接入；`curl` 桩三个新分支；
`tests/selfupdate.test.sh`（验收 5–12）。

**单元 C — 发布侧与文档**
`.github/workflows/release.yml`、`VERSION` → `1.2.0`、README / CLAUDE.md /
`docs/script-usage.md` / `docs/safe-update.md`。

### 与 spec 的三处偏差

1. **验收 1–3 不跑完整的 `install`。** `cmd_install` 第 7/8 步会 `sudo cp` 一份 plist 到
   `/Library/LaunchDaemons/sing-box.plist` —— 那个路径写死在 `$PLIST` 里，**不跟随
   `--prefix`**，跑到那一步就会动真实系统。改用 `SB_FAKE_CHECK_FAIL="live:<版本>"`
   让第 5/8 步静态校验失败而中止；启动器那一步（2/8）紧跟内核（1/8）之后，那时早已
   执行完，断言对象（存在 / 0755 / 逐字节相同 / `.prev` 的内容）一条不少。
   要真正跑完 `install`，得先让 `$PLIST` 可覆盖 —— 那是另一个独立改动。
   为此新增了两个 PATH 桩：`tests/fixtures/bin/networksetup` 与 `scutil`。

2. **判「当前进程是不是从 `$LAUNCHER` 启动的」，两边都过一次 `cd` + `pwd`。**
   spec 只说了对 `$0` 这么做。承重的是把 `$0`（可能是 `./singbox.sh` 这种相对路径）
   绝对化；两边都做只是为了对称，不额外解决什么。
   ⚠️ **这不解析符号链接** —— bash 的 `cd` 与 `pwd` 默认都是 `-L` 逻辑路径，
   `cd /var/tmp && pwd` 回的仍是 `/var/tmp`。所以 `$PREFIX/bin` 若是一条符号链接，
   本该 re-exec 的场景会退化成「只更新不重启」，那是安全的降级而不是数据损坏。
   要真解链接得手写循环读 `ls -l`（`readlink -f` 在 macOS 上不存在、也被自检第 4 项
   禁了），为这个边缘场景不值当。默认 `--prefix /usr/local` 下无实际影响。
   （这一条的原始记述把机制讲错了，`/sdlc-kit:review` 指出后改正。）

3. **`docs/script-usage.md` 第 1 节也有同一段 `~/bin` 手抄命令**，spec 只点名了
   `README.md` 2.5。同一件事说了两遍，只改一处就会自相矛盾，一并改了。
   另外 `CLAUDE.md` 原先写「四个测试文件」而实际已有六个，本次加到八个，顺手修正。

### 两处「不是恒绿」的验证

仓库的纪律是每一项都要有会被抓到与不该被抓到的样本。有四条断言在功能不存在时也会绿，
逐条验过：

- `update.test.sh` 的 rollback 两条 —— 用 `SB_UNDER_TEST` 指向 `HEAD` 那份没有启动器
  逻辑的脚本，两条都红（`.prev 还在=是`）。
- `selfupdate.test.sh` 的「远端 == 本地」「远端 < 本地」—— 用一份把
  `if ! ver_gt "$new" "$VERSION"` 短路成 `if false` 的变异脚本跑，两条都红。

为此给 `update.test.sh` 与 `selfupdate.test.sh` 都加了 `SB_UNDER_TEST`（沿用
`platform.test.sh` 已有的写法）。

### 自检第 13 项当场抓到的一个真缺陷

把 `--prefix` 那条 case 分支拆成多行去加 `LAUNCHER=` 之后，`shift 2` 与 `|| die` 护栏
不再相邻，**自检第 8 项立刻报了出来**。已合回一行，并在那里写明为什么不能拆。

### `/sdlc-kit:review` 抓到的一个真缺陷（已修）

**阶段 S 的 sha256 失配会 `die` 掉整条 `update`。** `download()` 在「直连下来的文件
校验对不上」那一档走的是 `die` 而不是 `return 1`，那个 `die` 会从 `_self_update` 里
`if ! download …` 的底下穿过去，整条 `update` 退出 1，**阶段 0–3 一个字节都跑不到** ——
正是「脚本更新不该有权阻断用户真正要的那件事」禁止的。

修法是把那次调用套进子 shell，让 `die` 只杀子 shell。不改 `download()` 本身：它是
`install` 与内核升级共用的函数，改它的返回语义会波及内核路径，而 spec 明确划了
「不改内核升级的三阶段逻辑」。子 shell 安全的前提已实测：bash 3.2 的 `( )` **不继承
EXIT trap**，否则 `cleanup` 会在子 shell 退出时把 `$tmpd` 连同刚下好的文件、以及本进程
持有的 `$LOCKDIR` 一起删掉（子 shell 里 `$$` 仍是父进程的 PID）。

原先的验收缺口在于第 8 条只覆盖「取不到远端版本」。补第 13 条：curl 桩新增
`SB_FAKE_SELF_BAD_SHA=1` 报一个对不上的 digest，断言 `update` 仍退出 0、启动器
sha256 不变、且日志里同时有「sha256 不匹配」与「已是最新」（后者证明确实走到了内核阶段）。
修之前这条红在「退出 1，到过阶段 0 = 0 次」。

### 待定问题的状态

`v1.2.0` 这个 tag **没有推**，按 spec 归 lzyMeta 手工做。在那之前阶段 S 永远走
「取不到新版 → warn → 照升内核」，该路径有验收第 8 条覆盖。
「自更新从 `v1.2.1` 起才真正闭环」已写进 `docs/script-usage.md`，发版时须进 release notes。

`release.yml` 的两条手工核对未做（需要真的推 tag），写进 PR 描述：
tag 与 `VERSION` 一致时能建出带 `singbox.sh` asset 的 release；故意推一个不一致的 tag 时红。

