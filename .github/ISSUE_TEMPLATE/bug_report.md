---
name: 问题反馈
about: 脚本报错或行为不符合预期
title: ''
labels: bug
---

**环境**
- macOS 版本：
- 芯片：Intel / Apple Silicon
- sing-box 版本：`sing-box version` 的输出
- 脚本版本：`./singbox.sh --version` 的输出

**复现步骤**
执行了哪条命令，在第几步出错。

**诊断信息**
跑一次 `./singbox.sh doctor`，把 `/tmp/singbox-doctor-*.txt` 的内容贴上来。

> **贴之前请自行删除敏感信息**：节点地址、SNI、公钥、UUID、公网 IP。
> doctor 输出里包含配置校验结果和日志，可能含有这些内容。

**预期行为**
你以为会发生什么。
