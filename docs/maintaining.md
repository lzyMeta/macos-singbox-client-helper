# 维护者手册

改代码的人看的。操作手册是 `manual-*.md`（README 第 4 节有表），方案与原理在 [best-practices.md](best-practices.md)，
每轮改动的设计记录见 README 第 4 节。

## 验收

```bash
./singbox-selfcheck.sh && ./tests/run.sh
```

每个测试文件盯什么、运行环境的硬约束（bash 3.2、BSD 工具链、Rosetta 下的架构判定）、
这台机器上有 live sing-box 时哪些命令不能跑——都在仓库根目录的 `CLAUDE.md`，不在这里重复。

## 发版

两步，两个技能，都不手工敲 `git tag` / `git push` / `gh release`：

```
/sdlc-kit:tag [patch|minor|major|<版本号>]   # bump singbox.sh 的 VERSION、提交、打 annotated tag、只推这一个 ref
/sdlc-kit:release                           # 触发 release.yml 建 Release，核实 releases/latest 已指向它
```

`tag` 打完对用户**不可见**——`update` 阶段 S 读的是 `releases/latest`，不是 tag；`release` 的最后一步
`sdlc-release verify` 才是「发好了」的凭据。配置在 `.claude/sdlc.json` 的 `release` 节（`channel: release`、
版本文件 `singbox.sh` 的 `VERSION=` 行、asset `singbox.sh`）；契约三条在 `.github/workflows/release.yml` 文件头。
⚠️ 换过 `release.yml` 之后要先随一个普通 commit 推到 `main`，`gh workflow run` 才找得到它。

已知限制：`ver_gt()` 把非数字段按 0 处理（`1.3.0-rc.1` 的第三段按 0 算），所以装了 `-rc` 版的用户
**不会被推到同号正式版**。目前没有给测试者发 rc 的需求；有了再改 `ver_gt()`，不在这里绕。

## 文档怎么不漂移

两层，各管一半：

- **sdlc-kit 的 `sdlc-doc`**（通用规则 D1–D10）：引用了已删除的路径、订正贴在旁边不折回正文、
  两处逐字重复的段落、手册超过 120 行或混进原理、设计记录没标 `status`、`covers` 点名的文件
  改了而文档没动（改提交时提醒）。`sdlc-doc lint` 已注册为 `check.commands` 的 `doc` 项（sdlc-kit ≥ 0.2.8：
  `sdlc-check` 会把自己的 bin 放进检查命令的 PATH，闸门的裸 PATH 下也能找到它）。
- **`tests/docs.test.sh`**（本项目特有的事实，通用工具不可能知道）：分发表里的子命令要出现在
  README 命令表、内置 help 和某份手册里；`config audit` 的旗标；README 仓库结构与文档索引；自检项数；
  `best-practices.md` 的配置全文（必须与 `config/config.example.json` 逐字相同）；README 与
  best-practices 的目录；手册里不许出现 `singbox.sh:行号`。测试文件数是 CLAUDE.md 里的 `sdlc-doc:n` 块，归 D2。

文档的 `kind`：5 份操作手册是 `manual`（D4：≤ 120 行、四个固定 H2「前提 / 步骤 / 出错了看哪 / 深入阅读」、
不许有原理段——原理写进 `best-practices.md` 第 9 节，手册只留链接）；5 份设计记录是 `spec`（`status: shipped`）；
`best-practices.md` 是 `design`。`covers` 写的是「改了这些文件就该回看这份文档」。本文没标 kind。

## 迁移表怎么维护

**网站是活的，内核是死的。** 首页 changelog 已经是下一个 alpha，而审查对象是本机装着的那个版本。
表的每条都钉在 sing-box 的 **git tag**，网站只做人工核对。内核出新 minor 时：

1. 按 tag 读四处源：`docs/deprecated.md` / `docs/migration.md` / `docs/changelog.md`（三页的源）、
   `experimental/deprecated/constants.go`（内核真正会告警的 Note）、`option/*.go` 里 `schema:"omit"` 的字段
   （schema 路的精确定义）、`deprecated.Report` 的调用点（标每条是 `New()` 阶段 `check` 能抓，还是 `Start()` 阶段只有沙箱日志能抓）。
   ```bash
   curl -fsSL https://raw.githubusercontent.com/SagerNet/sing-box/v1.15.0/docs/migration.md
   ```
2. 往 `_cfg_pylib` 的 `TABLE` 加条目：`id` / `match`（`key` 路径模式或 `usage` 具名谓词）/ `deprecated_in` /
   `removed_in` / `tier` / `stage` / `warn`（把 WARN 原文对回本条的正则）/ `link` / `note` / `fix` / `rewrite`。
   **链接写整段字面量，不拼接**——`tests/config-audit.test.sh` 的锚点核对是 grep 源码做的。
3. 从新 tag 的 `docs/migration.md` 重新生成 `tests/fixtures/migration-anchors.txt`（生成规则写在文件头注），
   把 `CFG_TABLE_COVERS` 改成新 minor。
4. 概括性文字复现不出正确的改写：`snippet` 型条目的语义只从源码取（例子：文档说地址过滤「只对地址查询生效」，
   源码是整条规则跳过——按文档写出的等价形式会多一条永远不该有的兜底）。
5. 文档与内核互有遗漏，两个方向都有：内核 WARN 给的链接可能是死链（1.14.0 的 `strategy`）；deprecated 页会漏
   （Hysteria v1 调优字段、`tun.endpoint_independent_nat`）；也会说已移除而内核仍接受（`block` 出站）。
   每条的 `note` 里把这类出入写清楚。
6. `fix` 不是 `auto` 的条目，**同时**在 [config-audit-findings.md](config-audit-findings.md) 加一节 `### <id>`，
   四段（问题是什么 / 模板里的例子 / 怎么判断 / 改成什么样）都要写——报告详情区的「解读」链接锚到这一节。
   `tests/docs.test.sh` 第 9 项把表与文档双向钉死：多一条、少一节、缺一段都红。

四路发现层为什么缺一不可、`--apply` 四道验收各挡哪类错，见设计记录
[config-audit-migration-table.md](config-audit-migration-table.md)。
