---
kind: manual
covers:
  - config/config.example.json
---
# 改配置与配置审查

安全地改 live 配置、备份与回退、审查废弃字段并自动迁移。

## 前提

- 已安装。`config audit --config <文件>` 审任意文件不需要 root，其余要 sudo

## 步骤

1. 改配置

   ```bash
   singbox edit                        # 编辑器打开 → 验语法 → sing-box check → 备份 → 写入 → 重启
   singbox edit --editor nano          # 指定编辑器并记住
   singbox edit --editor "code -w"     # GUI 编辑器务必带等待参数
   singbox edit --editor mate --once   # 只用这一次
   singbox edit --show-editor          # 看当前会用哪个
   singbox edit --reset-editor         # 清除偏好
   ```

   两关校验都过才写入；任一关不过，原配置不动，你的修改保留在 `/tmp/sb-edit-failed-*.json`。
   编辑器优先级：`--editor` > 记住的偏好 > `$EDITOR` > `vi`，不可用就逐级降。

2. 备份与回退

   ```bash
   singbox config show
   singbox config backup
   singbox config list                 # 带时间戳，自动保留最近 10 份
   singbox config diff [备份路径]       # 默认与最近一次比
   singbox config restore [备份路径]    # 默认恢复最近一次
   ```

3. 审查废弃字段

   ```bash
   singbox config audit                        # 审 live 配置，离线、毫秒级
   singbox config audit --config ./some.json   # 审任意文件
   singbox config audit --deep                 # 再起一次沙箱收内核运行时的告警，要网络
   ```

   报告是一张汇总表加编号详情，只看「结论」与「怎么办」两列，看不懂的按详情区「解读」链接过去：
   「将来会坏」按编号到详情找链接；
   「提示」是行为变更提醒，配置照旧合法。退出码：`0` 干净、`2` 有废弃项但现在能跑、
   `1` 内核已经不接受。升级内核前跑一次。

4. 自动迁移

   ```bash
   singbox -n config audit --apply    # 预演：列出会改哪些键、各几处，四道验收过不过
   singbox config audit --apply       # 真改：备份 → 改写 → 验收 → 落地并重启
   ```

   | 旧写法 | 改成 |
   |---|---|
   | 规则集的 `download_detour: "X"` | `http_client: {"detour": "X"}` |
   | `dns.independent_cache` | 删掉 |
   | `experimental.cache_file.store_rdrc: true` | `store_dns: true`（已有 `store_dns` 或值为 false 则只删） |

   只改这三类，别的一律只报不改。四道验收（结构 diff 只落在这三处、`sing-box check`、
   沙箱起得来、重跑审查归零）任一道不过就不落地。三处命中都是 0 时报「无需改写」直接退出。

## 出错了看哪

- **`edit` 保存后报校验失败** → 修改在 `/tmp/sb-edit-failed-*.json`，改好后 `edit` 再粘回去。
- **`edit` 一打开就说「没改动」** → GUI 编辑器没带等待参数，用 `--editor "code -w"`。
- **记住的编辑器被卸载了** → 会自动清除偏好并降级，重新 `--editor` 指定即可。
- **`--apply` 改坏了** → `singbox config restore`，回到 `--apply` 前的备份。
- **`--apply` 被拒「内核低于 1.14.0」** → 先升内核（[升级](manual-update.md)），再迁移。
- **`--apply` 与 `--config` 不能同用** → `--apply` 只作用于 live 配置，它的回退点是 `config restore`。
- **报告说「迁移表只覆盖到 1.14.0」** → 内核比表新，用 `--deep` 或查官方 deprecated 页。
- **`--deep` 注明「日志可能不完整」** → 远程规则集没下到，沙箱没起来；联网后重跑。
- 直接 `sudo vi` 改也行，但没有校验、没有备份、不会重启——sing-box 不监听文件变化，改了不重启等于没改。

## 深入阅读

- [配置逐字段详解](best-practices.md#2-配置逐字段详解)
- [版本兼容对照](best-practices.md#29-版本兼容对照)
- [编辑器偏好为什么只记「显式指定且可用」的](best-practices.md#95-edit-的编辑器回退)
- [config audit 的四路发现层与四道验收（设计记录）](config-audit-migration-table.md)
- [config audit 结论解读：每条「怎么办」背后的问题、模板例子与判断方法](config-audit-findings.md)
- [迁移表怎么维护](maintaining.md#迁移表怎么维护)
