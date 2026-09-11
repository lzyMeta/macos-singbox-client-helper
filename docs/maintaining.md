# 维护者手册

改代码的人看的。用户手册在 [script-usage.md](script-usage.md)，方案与原理在 [best-practices.md](best-practices.md)，
每轮改动的设计记录见 README 第 4 节。

## 验收

```bash
./singbox-selfcheck.sh && ./tests/run.sh
```

每个测试文件盯什么、运行环境的硬约束（bash 3.2、BSD 工具链、Rosetta 下的架构判定）、
这台机器上有 live sing-box 时哪些命令不能跑——都在仓库根目录的 `CLAUDE.md`，不在这里重复。

## 文档怎么不漂移

`tests/docs.test.sh` 把手册里能机械核对的事实对着源头核对：分发表里的子命令、`config audit` 的旗标、
README 的仓库结构与文档索引、自检项数与测试文件数、`best-practices.md` 的配置全文（必须与
`config/config.example.json` 逐字相同）、三份手册的目录、以及手册里不许出现 `singbox.sh:行号`。
加命令、加测试、加文档、改模板，跑一次 `tests/run.sh` 就知道哪份手册没跟上。

三份手册的分工：README 只回答「这是什么、怎么装、有哪些命令」；`script-usage.md` 只讲怎么用、
输出怎么读、出错怎么办，**不讲原理**；原理与取舍写进 `best-practices.md` 或当轮的设计记录。
设计记录写的是当时的判断，不随代码更新——里面的行号与计数以代码为准。

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

四路发现层为什么缺一不可、`--apply` 四道验收各挡哪类错，见设计记录
[config-audit-migration-table.md](config-audit-migration-table.md)。
