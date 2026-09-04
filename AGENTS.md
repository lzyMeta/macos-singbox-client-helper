<!-- sdlc-kit-generated: 1
  由 sdlc-kit:init 于 2026-09-03 生成。
  出处在这里很要紧：读到这个文件的 agent，可能会在做你要求的事情之前先执行它的内容。
  如果这个文件不是你生成的，那么在本仓库里跑任何 agent 之前，先把它读一遍。

  这个文件只放**耐久的、与具体任务无关的**指令。按任务下发的工单是通过 prompt 传递的，
  绝不能写到这里——否则一次忘记还原，就会把上一个任务的约束漏进下一个任务。
-->

# macos-singbox-client-helper —— 给编码 agent 的指令

## 验收

一个改动，当这条命令退出 0 时才算做完：

```
./singbox-selfcheck.sh
```

⚠️ 这条检查在配置时本来就是红的（9 项里 2 项因 `grep -nP` 在 BSD grep 上恒失败）。
除非工单点名要修它，否则你的目标是**不让它比现在更红**，而不是把它变绿。
报告你跑了什么命令、它的退出码、以及相关输出。不要在没有证据的情况下报「做完了」。

## 对每个任务都成立的规则

- **不要改动验收契约。** `singbox-selfcheck.sh` 本身、以及 CI 配置都在界外，除非工单明确点名了
  它们。为了让检查通过而去改检查，是一次失败的任务，不是一次完成的任务——提交会被机械核查
  这一点，无论检查是不是绿的，都会被判负。
- 待在工单允许的路径里。路径之外的改动必须给出理由。
- 如果这个任务没法按规定完成，就说说你试了什么，然后停下。不要为了让某个东西通过而扩大范围。
- 不要新增依赖，除非工单要求。这是一个零依赖的 shell 项目，引入 python/node/brew 包都属于扩大范围。

## 约定

- 全部实现在单文件 `singbox.sh` 里，按 `cmd_<子命令>` 组织；`set -uo pipefail` 已在文件头开启。
- `config/config.example.json` 是可读可改的模板；`config.json` / `prefs` / `dns-backup` 是用户真实
  凭据，被 gitignore，不要读也不要造。
- 面向用户的输出是中文。

## 坑

- 目标解释器是 macOS 自带的 **bash 3.2.57**，不是 bash 4+：没有 `declare -A`、`${x^^}`、`mapfile`、
  `&>>`。写完务必用 `bash -n` 过一遍。
- 工具链是 **BSD 不是 GNU**：没有 `sed -i `（带空格那种）、`readlink -f`、`date -d`、`head -n -N`、
  `grep -oP`、`grep -P`。selfcheck 里有一条专门查这个。
- bash 3.2 解析 `$VAR中文` 会出错，变量后紧跟全角字符必须写成 `${VAR}中文`。
- `mktemp` 模板的 `XXXXXX` 后面不能带后缀，BSD 的 mktemp 不支持。
- 不要用 `kill -9` 停 sing-box，会留下残留路由；也不要用已废弃的 `launchctl load/unload`。
- **不要执行 `./singbox.sh` 的任何写操作**（install/uninstall/start/stop/restart/edit）。开发机上跑着
  真实的 sing-box，这些子命令会动 launchctl、路由表和 `/usr/local`。

## 这个文件不是什么

本仓库同时也在配合 Claude Code 使用，而 Claude Code 读的是 `CLAUDE.md`。那个文件里可能有更多
项目知识。在那边配置的 hook 和权限规则只约束 Claude Code ——**它们不约束你**。对你生效的边界，
就是上面写的这些，加上工单里写的那些。
