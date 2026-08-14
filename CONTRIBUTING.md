# 参与说明

本仓库以个人使用为目的维护，许可不允许再分发。欢迎提 issue 反馈问题；
提交 PR 前请先开 issue 讨论，避免白做。

## 提问题时

跑一次 `./singbox.sh doctor`，附上诊断文件的内容。
**贴之前删掉敏感信息**：节点地址、SNI、公钥、UUID、公网 IP。

## 改脚本时

改完先跑静态自检：

```bash
./singbox-selfcheck.sh singbox.sh
```

它覆盖了几类在 Linux 上测不出来、只在 macOS 上炸的坑：

| 检查 | 为什么 |
|---|---|
| 变量紧贴全角字符 | bash 3.2 会把全角字符的字节吞进变量名 |
| `mktemp` 模板带后缀 | BSD 版要求 `XXXXXX` 必须在末尾 |
| 数组在 `set -u` 下裸展开 | 空数组会报 unbound |
| GNU 专有命令 | `sed -i`、`readlink -f` 等 macOS 没有 |
| `kill -9` | 强杀会留下残留路由 |
| 遗留 `launchctl load/unload` | 报错含糊，应用 `bootstrap`/`bootout` |

自检通过不代表功能正确，仍需在真机上验证。

## 几条不要破坏的约定

- 只读命令（`verify`、`syscheck`、`rules`、`status`）不应要求 sudo
- 任何覆盖配置的操作前必须备份
- 停止进程一律 SIGTERM，等待后仍在则警告，**不强杀**
- 交互操作在非 tty 环境下应自动取默认值，不能卡住
