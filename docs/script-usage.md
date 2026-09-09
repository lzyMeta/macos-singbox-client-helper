# `singbox.sh` 使用说明

sing-box 在 macOS 上的全生命周期管理工具：安装、配置、验证、运行、排查、升级、卸载。
配套 [best-practices.md](best-practices.md)。

---

## 目录

- [1. 安装脚本本身](#1-安装脚本本身)
- [2. 首次使用](#2-首次使用)
- [3. 命令速查](#3-命令速查)
- [4. `install` — 首次安装](#4-install-首次安装)
  - [七个步骤](#七个步骤)
  - [为什么不用 Homebrew 装内核](#为什么不用-homebrew-装内核)
  - [步骤 2 为什么不能跳](#步骤-2-为什么不能跳)
- [5. 日常运行](#5-日常运行)
  - [`status`](#status)
  - [启停与自启](#启停与自启)
  - [`logs`](#logs)
- [6. 检查与验证](#6-检查与验证)
  - [`verify` — 完整验证](#verify-完整验证)
  - [`syscheck` — 换网络后必跑](#syscheck-换网络后必跑)
  - [`rules` — 验证规则集](#rules-验证规则集)
  - [`debug` — 看分流命中](#debug-看分流命中)
  - [`doctor` — 一键诊断](#doctor-一键诊断)
- [7. 配置管理](#7-配置管理)
  - [`edit` — 安全地改配置](#edit-安全地改配置)
  - [`config` — 备份与回滚](#config-备份与回滚)
- [8. 维护](#8-维护)
  - [`update` — 升级内核](#update-升级内核)
  - [`rollback` — 换回上一个内核](#rollback-换回上一个内核)
  - [`uninstall`](#uninstall)
- [9. 边界情况的处理](#9-边界情况的处理)
- [10. 常见问题](#10-常见问题)

---

## 1. 安装脚本本身

```bash
mkdir -p ~/bin
cp singbox.sh ~/bin/singbox
chmod +x ~/bin/singbox
```

`chmod +x` 是给文件加执行权限——没有它 shell 会拒绝把文件当程序跑，报 `Permission denied`。

`~/bin` 不在 PATH 里的话（`echo $PATH` 看不到就是），先确认你用的 shell：

```bash
echo $SHELL
```

macOS 从 Catalina 起默认是 **zsh**，写错文件不会生效：

```bash
# zsh
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
# bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bash_profile && source ~/.bash_profile
```

验证：

```bash
which singbox        # 应输出 /Users/你/bin/singbox
singbox --help
```

仍报 not found 就**新开一个终端窗口**再试——新窗口一定会重读 rc 文件。zsh 还有命令缓存，`hash -r` 可清。

从浏览器下载的话先解除隔离标记：

```bash
xattr -d com.apple.quarantine ~/bin/singbox 2>/dev/null
```

不想装进 PATH 的话，`./singbox.sh <命令>` 直接跑也一样。

---

## 2. 首次使用

```bash
singbox -n install --config ./config.json   # 先空跑看会做什么
singbox install --config ./config.json      # 真正执行
```

**准备两样东西**：

1. **填好的配置文件。** 七个占位符必须全部替换：`YOUR_VPSTRANS_ADDR`、`YOUR_SNI`、`YOUR_PUBLIC_KEY`、`YOUR_SHORT_ID`、`YOUR_UUID_VPSTRANS`、`YOUR_UUID_VPSRE`、`YOUR_CLASH_SECRET`。两个 UUID 必须是标准的 8-4-4-4-12 格式。
2. **管理员密码。** TUN 建虚拟网卡、改路由表必须 root。

装完还有两件事脚本做不了，它会提醒你：**关闭浏览器内置 DoH**，以及跑一次 `singbox rules`。

---

## 3. 命令速查

```
singbox <命令> [参数]
```

| 分类 | 命令 | 用途 |
|---|---|---|
| 安装 | `install` | 首次安装：内核 + 系统层 + 配置 + 服务 |
| | `sysprep` | 只做系统层准备（换网络后修复 IPv6/DNS） |
| 运行 | `status` | 服务、TUN 路由、监听端口 |
| | `start` / `stop` / `restart` | 本次开机内的启停，停服可连带还原 DNS |
| | `enable` / `disable` | 开机自启开关（跨重启） |
| | `logs [n\|-f\|size\|truncate]` | 看日志、看体积、原地回收空间 |
| 检查 | `verify` | 完整验证清单 |
| | `syscheck` | 系统层复查 |
| | `rules` | 验证规则集 URL |
| | `debug` | debug 前台跑，看分流命中 |
| | `doctor` | 收集诊断并自动判读 |
| 配置 | `edit [--editor <cmd>]` | 改配置（校验 + 备份 + 重启），编辑器可记忆 |
| | `config show\|backup\|list\|diff\|restore` | 配置与备份管理 |
| 维护 | `update` | 升级内核：预检 → 沙箱验证 → 升级 → 验收，任一阶段失败自动回滚 |
| | `rollback` | 换回上一个内核（`.prev`）并重新验收 |
| | `dns` | 系统 DNS 的查看与切换 |
| | `mirror` | GitHub 下载镜像的探测与固定 |
| | `uninstall` | 卸载 |

**全局参数**（放在命令之前）：

| 参数 | 作用 |
|---|---|
| `-n`, `--dry-run` | 只打印将要执行的操作，不动手 |
| `-y`, `--yes` | 非交互，所有询问取默认值 |
| `-q`, `--quiet` | 只输出警告与错误 |
| `--prefix <dir>` | 安装前缀，默认 `/usr/local` |

不带命令等同 `status`。

---

## 4. `install` — 首次安装

```bash
singbox install [--config <path>] [--version <v>] [--arch <amd64|arm64>] [--force]
```

| 参数 | 说明 |
|---|---|
| `--config` | 配置文件。不给则依次找 `./config.json`、`./config.json`、`~/singbox/config.json` |
| `--version` | 内核版本。不给则查 GitHub 取最新 |
| `--arch` | `amd64` \| `arm64`，取值会当场校验。默认按**硬件**判断（`hw.optional.arm64`），不是按 `uname -m` |
| `--force` | 已安装时不询问，直接重装内核 |

### 七个步骤

| 步 | 做什么 |
|---|---|
| 0 | 架构检查、**配置静态检查**（占位符、JSON 语法） |
| 1 | 从官方 release 装内核，读编译标签 |
| 2 | 系统层准备：IPv6、DNS、冲突客户端 |
| 3 | 放置配置，修正 `cache_file` 相对路径与 `stack` |
| 4 | `sing-box check` 静态校验 |
| 5 | 前台跑 25 秒，观察规则集下载与 TUN |
| 6 | 写 plist、`plutil -lint`、`bootstrap` 加载 |
| 7 | 自动跑 `verify` |

**配置检查放在步骤 0** 是有意的：占位符没换、JSON 写坏这类问题，不该等下载完几十 MB 的内核才发现。

### 为什么不用 Homebrew 装内核

两个理由：**构建标签不保证**（本方案用 gvisor 栈，而 Homebrew 从源码构建时是否带 `with_gvisor` 没保证）；**Homebrew 本体可能跟不上系统**（较新 macOS 上会报 `unknown or unsupported macOS version`）。sing-box 是单文件二进制、没有依赖链，手动装反而更稳。

### 步骤 2 为什么不能跳

这三件事配置文件管不了，不做的话后面验证一定过不去，而**症状完全不指向真正的原因**：

* **IPv6 未关** → TUN 只接管 IPv4，系统的 IPv6 默认路由仍指向物理网卡，那部分流量绕过全部规则直连。
* **DNS 是内网地址** → `192.168.1.0/24 via en0` 比默认路由更具体，查询不进 TUN，明文出网被投毒。典型症状是 `google.com` 解析成 `157.240.x.x`（Facebook 的段）。
* **其他 VPN 在跑** → macOS 上同时只能有一个 TUN 客户端正常工作。

> 脚本只检测冲突进程并提示，不代你退出——退出应该用各客户端自己的方式，**别用 `kill -9`**。

---

## 5. 日常运行

### `status`

三段：服务（进程、LaunchDaemon、自启）、TUN 与路由、监听端口。

两个判读要点：

* **指向 `en0` 的那条 `default` 必须保留**，不是残留——内核自己的出站流量要靠它才出得去。判据是"有没有一条指向 utun"，不是"只剩 utun 一条"。
* **监听地址应为 `127.0.0.1`**。显示 `*:10808` 说明配置里 `listen` 写成了 `0.0.0.0`，局域网内谁都能用你的代理，脚本会警告。

### 启停与自启

```bash
singbox stop      # 本次开机内停止
singbox start
singbox restart   # 改完配置用这个

singbox disable   # 彻底停用，重启后也不启
singbox enable
```

**`stop` 与 `disable` 是两回事**：`stop` 卸载 job，只对本次开机有效——plist 还在，重启电脑照样自启。跨越重启的调试期间要用 `disable`，否则重启后服务自己回来，还会占着端口干扰前台调试。

> `disable` 会先 `bootout` 再写停用标记，所以**当前服务也会立即停止**。但它管不了 `debug` 或手动前台跑的实例——那些不受 launchd 管辖，脚本会提示你回终端 `Ctrl-C`。

#### 停服会连带处理系统 DNS

代理运行时系统 DNS 指向 `1.1.1.1`（见第 4 节 install 的步骤 2）。**代理一停，这个设置反而有害**——明文查询 `1.1.1.1` 在国内同样会被污染，表现是某些网站解析出错误 IP、打不开。

所以 `stop`、`disable`、`uninstall` 都会检测这一点并询问是否还原：

```
! 系统 DNS 仍指向 1.1.1.1 —— 代理已停，这个地址的明文查询在国内会被污染
  还原为路由器下发的 DNS？ [Y/n]
```

不想每次被问的话：

```bash
singbox stop --dns-dhcp       # 直接交回 DHCP（路由器下发），不问
singbox stop --restore-dns    # 按备份回滚，不问
singbox stop --keep-dns       # 保留代理 DNS，不问
singbox stop --dns 223.5.5.5  # 指定地址
singbox disable --dns-dhcp
```

**默认是按备份精确回滚**：首次 `install` 设置 DNS 之前，脚本会把每个网络服务的原值记进 `~/.config/singbox/dns-backup`，还原时逐条写回。原来是 `223.5.5.5` 就还原成 `223.5.5.5`，原来就是 DHCP 才交回 DHCP。

> **备份里等于 `1.1.1.1` 的条目会被当成 DHCP 处理。** 如果你在装脚本之前就手动把 DNS 设成了 `1.1.1.1`（按方案文档的步骤），备份记下的就是这个值——照着回滚等于没还原。所以写备份和读备份两处都会把它归一化为"交回 DHCP"。
>
> 拿不准就直接用 `--dns-dhcp`，它不看备份。

还原后会**回读实际生效值**打印出来，避免"以为还原了其实没有"。

#### `dns` 子命令

```bash
singbox dns status          # 当前 DNS、是否与服务状态匹配、备份内容
singbox dns dhcp            # 交回 DHCP（路由器下发）
singbox dns backup          # 按备份还原
singbox dns proxy           # 设为代理模式（1.1.1.1）
singbox dns set 223.5.5.5   # 设为指定地址
```

`dns status` 会交叉检查服务状态与 DNS 状态，两者不匹配时给出建议：

| 服务 | DNS | 提示 |
|---|---|---|
| 在跑 | 代理模式 | 正确 |
| 在跑 | 非代理 | 查询可能不进 TUN 被投毒 → `dns proxy` |
| 未跑 | 代理模式 | 明文查询会被污染 → `dns dhcp` |
| 未跑 | 非代理 | 正确 |

反过来，`start` 时若发现 DNS 不在代理模式，会提醒并询问是否设回——**这一步别跳过**，否则代理起来了但查询不进 TUN，仍然会被投毒。

> `uninstall` 除了 DNS，还会询问是否把 IPv6 还原为自动。两项都是当初为防泄漏改的系统级设置，卸载时理应有机会还原。

### `logs`

```bash
singbox logs           # 先报体积，再打后 50 行
singbox logs 200
singbox logs -f        # 跟随
singbox logs size      # 只看体积
singbox logs truncate  # 原地清空，回收空间
```

**launchd 不做日志轮转。** plist 把 stdout/stderr 直接指向
`/var/log/sing-box.log` 与 `/var/log/sing-box.err`，launchd 只管往里写——
不轮转、不封顶。实测能涨到几百 MB，而在此之前没有任何命令提过一句。
现在 `status` 与 `doctor` 超过阈值（默认 64 MB，`SB_LOG_WARN_MB` 可改）会点名并指向回收命令。

**为什么回收是「原地截断」而不是轮转。**
`StandardErrorPath` 那个 fd 是 launchd 打开、`dup2` 到子进程 fd 2 上的。
一旦换了 inode（`mv`、`rm` 后重建、或任何 rename 式轮转），守护进程会一直往那个
已经没有名字的旧文件里写：磁盘一点收不回来，而且从此再也看不到新日志。
`logs truncate` 用的是 `: > 文件`，inode 不变，所以服务不受影响、不用重启。

**为什么不配 newsyslog。**
macOS 的 `newsyslog` 只会 rename + 新建，没有原地截断的选项
（`man newsyslog.conf` 的 flags 里 `B/C/D/G/J/N/U/Z` 没有一个是截断）。
给这份 plist 配上去，等于装了一个看着在管日志、实际让守护进程往已归档文件里写的东西——
比不装更糟。所以这里不装，代价是回收要手动跑一次 `logs truncate`。

> 日志目录可用 `SB_LOGDIR` 覆盖（默认 `/var/log`）。它在 `install` 时会被烧进 plist，
> 所以改了要重新 `install` 才生效。

---

## 6. 检查与验证

### `verify` — 完整验证

五步，按依赖顺序，前一步失败后面就没意义：

| 步 | 验什么 | 失败意味着 |
|---|---|---|
| 1 | SOCKS 出口（绕开 TUN） | **节点参数问题**，与 TUN、路由无关 |
| 2 | **两个出口 IP 是否不同** | 服务端 UUID 分流未生效或中转断了 |
| 3 | DNS 是否被投毒 | 系统 DNS 可能是内网地址 |
| 4 | IPv6 / QUIC | 见 `syscheck` |
| 5 | 国内直连、局域网 | 规则顺序或规则集问题 |

**退出码分两档**，判据是「回滚到旧内核能不能把它换回来」：

| 退出码 | 含义 | 典型分支 |
|---|---|---|
| `0` | 全过 | — |
| `1` | **链路档**失败，换内核有可能修好 | SOCKS 不通；兜底取不到 IP；两个出口相同；存在全局 IPv6 |
| `2` | **策略档**失败，回滚换不回来 | DNS 疑似污染或解析手段全废；QUIC 未被阻断；国内出口等于 SOCKS 出口；取不到默认网关或网关不通；`ipinfo.io` / `cip.cc` 那几个参照站全取不到 |

`update` 的阶段 3 只认 `1` 才回滚，`2` 打条 `warn` 放行——路由策略坏了，换回旧内核一个字都改不了。

**五步里没有任何静默跳过。** 每一步都会打印判定结果：`dig` 不可用会自动降级到
`host` → `dscacheutil` → `python3`，四级全废才报「本机没有可用解析手段」（这与「疑似污染」
是分开的两条错，别搞混）；QUIC 不再依赖 `curl --http3`（本机那个 curl 压根没编 HTTP/3），
改为直接发一个 QUIC 版本协商包看对端回不回；第 5 步也不再只是打印，它现在会断言
**国内直连出口 ≠ SOCKS 出口**。

**第 2 步是全脚本最关键的一项。** 日志只能证明"这条连接派给了 `vpsre` 出站"，**证明不了 vpsre 的出口真是住宅 IP**——那段中转在服务端，客户端看不见。中转挂了的话日志照样打 `outbound/vless[vpsre]`，出口却已变回机房 IP。这是客户端侧唯一能发现它的手段。

> 该判断依赖 `ipinfo.io` 命中社交组。不确定的话用 `singbox debug`，另开终端 `curl -s https://ipinfo.io/json >/dev/null`，看那条连接方括号里是 `vpsre` 还是 `vpstrans`。

### `syscheck` — 换网络后必跑

**最容易忘、也最该记住的一条。** IPv6 与 DNS 设置按**网络服务**生效、**不会继承**，以下情况都会留下缺口：

* 插 USB / 雷雳转以太网适配器 → 系统新建 `Ethernet` 服务
* 数据线连 iPhone 走热点 → 新建 `iPhone USB` 服务
* 公司 VPN 或 Tailscale 接管过 DNS，退出时没还原
* 系统设置里切换过"位置"

不合格时跑 `singbox sysprep` 修复。

> `fe80::`（链路本地）与 `::1`（环回）属正常，关不掉也不该关。脚本只报全局地址。

### `rules` — 验证规则集

**为什么必须验**：规则集下载失败时 sing-box **不会拒绝启动**，只在日志里留一条告警，然后那条规则永远不命中。表现是"某类流量莫名走了兜底"，而规则表看起来完全正确——**这是整套方案里最隐蔽的一类故障**。

404 基本都是分类名不对：`x` 上游可能叫 `twitter`、`meta` 可能叫 `facebook`、`apple@cn` 有的源写 `apple-cn`。

**内核大版本升级后建议跑一次**——`.srs` 有格式版本，新内核可能读不了旧文件。

### `debug` — 看分流命中

停掉服务、以 debug 级别前台运行，`Ctrl-C` 后**自动恢复服务**。

正常浏览一会儿，看每条连接落在哪个出站：

```
INFO [...] outbound/vless[vpsre]: outbound connection to <某个 tiktok 域名>:443
```

**方括号里的出站 tag 就是路由结果。**

### `doctor` — 一键诊断

收集全套信息写入 `/tmp/singbox-keep-*/doctor-*.txt`（目录 0700、文件 0600 —— 转储里有访问过的域名、出站 tag 与日志），并自动判读十类问题：权限不足、端口占用、规则集下载失败、FakeIP 泄漏、DNS 投毒、废弃字段、路由未接管、plist 语法、IPv6 未关、服务未运行。

退出码：0 未发现已知问题；1 命中了其中任何一条判据。

**出问题先跑它**，比逐条手敲快，输出也方便贴给别人。

---

## 7. 配置管理

### `edit` — 安全地改配置

复制到临时文件 → 编辑器打开 → `json.tool` 验语法 → `sing-box check` 验引用 → 备份 → 写入 → 重启。

**两关都过才写入。** 任一关不过就中止，原配置纹丝不动，**你的修改会保留到 `/tmp/sb-edit-failed-*.json`**，不会白改。

#### 指定编辑器

```bash
singbox edit --editor nano          # 用 nano，并记住
singbox edit                        # 之后直接用，自动是 nano
singbox edit --editor "code -w"     # VS Code，-w 不能少
singbox edit --editor mate --once   # 只用这一次，不改变记住的偏好
singbox edit --show-editor          # 看当前会用哪个
singbox edit --reset-editor         # 清除偏好
```

**`--editor` 会被记住**，写在 `~/.config/singbox/prefs`（用户级，不需要 root）。后续 `edit` 直接用它，不必每次带参数。

#### 解析优先级与回退

```
--editor 参数  >  已保存偏好  >  $EDITOR  >  vi
```

任一级不可用就降级到下一级，并说明原因：

| 情况 | 行为 |
|---|---|
| `--editor` 指的命令不存在 | 警告，降级到下一级，**不保存** |
| 已保存的编辑器后来被卸载了 | 警告，**自动清除该偏好**，降级 |
| 编辑器启动了但异常退出 | 询问是否改用 `vi` 重编；同意则清除偏好并重试，拒绝则不做任何修改 |
| 一个都不可用 | 直接报错，提示用 `--editor` 指定 |

> **只有"显式指定且确实可用"才会写入偏好**——回退得到的结果不会被记住，免得一次意外把错的编辑器固化下来。
>
> 带参数的编辑器（`code -w`、`subl -w`）没问题，验证时只看第一个词。GUI 编辑器**务必加等待参数**（`-w`），否则命令立刻返回，脚本会以为你没改动。

> 直接 `sudo vi` 改也行，但没有校验、没有备份，也不会自动重启——sing-box 不监听文件变化，**改了不重启等于没改**。

### `config` — 备份与回滚

```bash
singbox config show              # 查看当前配置
singbox config backup            # 手动备份
singbox config list              # 列出所有备份
singbox config diff              # 与最近一次备份比较
singbox config diff <备份路径>
singbox config restore           # 恢复最近一次备份
singbox config restore <备份路径>
```

备份带时间戳存在 `/usr/local/etc/sing-box/`，**自动保留最近 10 份**。`restore` 前会先校验该备份，不通过会警告但仍可继续（有时你就是要回到一个"能跑但有告警"的版本）。

---

## 8. 维护

### `update` — 升级内核

分四个阶段，**每个阶段失败都能退回一个已知可用的状态**：

| 阶段 | 做什么 | 失败了会怎样 |
|---|---|---|
| 0 预检 | 取当前版本与目标版本。跨 minor 额外确认一次 | 什么都没下载，直接退出 |
| 1 沙箱 | 把新内核装到**临时前缀**，验架构 → `check -c` 当前真实配置 → 用一份**派生配置**实跑，`curl -x socks5h://` 实测建链 | `$BIN` 一个字节都没被动过，现网服务全程在跑 |
| 2 升级 | `$BIN` → `$BIN.prev`，装新内核，`check -c`，重启，确认进程存活 / TUN 路由在 / 端口在听 | 换回 `.prev` 并重启 |
| 3 验收 | 跑 `verify` 五步。链路档失败隔 5s 重试一轮 | 链路档两轮都不过才回滚；策略档（退出 2）打 `warn` 放行 |

**为什么要有沙箱这一层。** `check -c` 校验的是配置文件的语法与字段合法性——字段还在、语义变了它照样过。sing-box 迭代快（`1.11` 换过 DNS 格式、`domain_strategy` 在 `1.14` 被移除、`independent_cache` 在 `1.14` 废弃），静态校验通过但新内核起不来、或起来了代理坏了，都是真实会发生的事。所以阶段 1 要真的把它跑起来试一次。

**派生配置**是必须的：现网服务还在跑的时候，第二个实例会在 `tun` 设备、`mixed` 的监听端口、`experimental.cache_file.path` 三处全部撞车。派生规则是删掉 `type == "tun"` 的 inbound、`mixed` 的端口换成从 `10900` 起探测到的第一个闲置端口、`cache_file.path` 指到临时目录。

⚠️ **沙箱验不到 TUN 与系统路由相关的回归**——派生配置把 `tun` 删了。这类问题只能在阶段 2/3 暴露，靠回滚兜底。这是「不停现网」换来的，是自觉的取舍。

**完整性校验做到哪一步。** 上游 release 的资产列表里确实**没有 checksum 文件**（没有 `checksums.txt`、`.sha256`、`SHA256SUMS`），但 GitHub Releases API 的每个 asset 带 `digest` 字段（`sha256:<hex>`），校验值从那里取。下载完当场比对，对不上就删文件并终止；取不到（老 release 无该字段、或 API 不可达）就打一条 warn 后放行，不装作校验过。

⚠️ 这道校验能挡的是**传输损坏**与**单个镜像投毒**。API 本身也可能是经镜像拿到的——那种情况下 digest 的可信度不高于那个镜像，挡不住「API 与文件出自同一个坏镜像」。它不是签名。

架构那一步仍然照验：sha256 只能证明「文件没被改」，不能证明「下对了平台」。

**废弃字段告警照打照记，但一个字都不自动改。** 「哪些字段该改成什么写法」需要读 release notes 和上游文档，那是另一件事。

升级成功后 `$BIN.prev` **保留**，留到下一次 `update` 才被覆盖——见下面的 `rollback`。

`.prev` 只由 `update` 写。`install` 不碰它：install 内部那个「新二进制跑不起来就换回去」的临时回滚点放在临时目录里，跑完随 `TMPFILES` 一起回收。（早先两者共用 `$BIN.prev`，于是 update 成功后再跑一次 install 会把退路无声删掉。）

升级后会提醒跑 `rules`。

```bash
singbox update            # 跨 minor 时会停下来问一次
singbox -y update         # 非交互。跨 minor 那道确认默认 n，于是会跳过而不是闷头升
```

### `rollback` — 换回上一个内核

```bash
singbox rollback
```

`$BIN.prev` 换回去 → 重启 → 跑一遍阶段 3 的验收。没有 `.prev` 就报错退出，什么都不动。

存在的理由是「当时一切正常，半小时后才发现某个网站进不去」——那时候升级流程早已结束，`update` 里的回滚分支帮不上忙。

⚠️ **只保留一份 `.prev`，只能退一步**，不能降级到任意历史版本。要更老的版本用 `install --version <v>`。

### `mirror` — GitHub 下载镜像

`install` 和 `update` 需要从 GitHub 下载内核。**直连失败时脚本会自动切换镜像**，不用你操心；这个命令是给你查看和干预用的。

```bash
singbox mirror test              # 探测直连与各镜像此刻是否可用（含耗时，全程数秒）
singbox mirror show              # 看候选顺序与已记住的镜像
singbox mirror set https://xxx   # 固定一个首选镜像
singbox mirror reset             # 清除，恢复默认
```

#### 自动回退是怎么工作的

**先快速探测，再真正下载**：

```
[1/5] 探测 直连 github.com … 不通
[2/5] 探测 镜像 https://ghfast.top … 不通
[3/5] 探测 镜像 https://gh-proxy.com … 可用
      下载内核 v1.14.0 ← 镜像 https://gh-proxy.com
      ############################## 100.0%
  ✓ 下载完成：18.4 MB，耗时 12s
```

探测用的是 HEAD 请求，**每个源最多等 6 秒、建连超时 4 秒**，死掉的镜像几秒内就跳过，不会让你干等。只有探通的源才会进入实际下载。

下载过程中若**速度持续 20 秒低于 2 KB/s**，判定为卡住，自动放弃并换下一个源——这比干等到超时快得多。

**成功的镜像会被记住**（存在 `~/.config/singbox/prefs`），下次优先用它——但直连仍然排在最前，网络恢复了自然会走直连，不会被镜像"粘住"。

> 进度条只在**终端里**显示。输出重定向到文件或管道时自动关闭，免得刷屏；`-q` 也会关掉。

版本号查询有三层兜底：GitHub API → 镜像上的 API → 解析 `releases/latest` 的 302 跳转地址。前两条都不通时，最后这条只需要能访问 github.com 的网页跳转即可。

#### 关于内置镜像列表

这类前缀式镜像站**更替频繁**，今天能用明天可能就停了。所以脚本的做法是：**内置一份列表，但每次都实测，探不通就换下一个**，而不是假定某个一定可用。

如果内置的全都不行，用自己的：

```bash
export SB_MIRRORS="https://your-mirror.example https://another.example"
singbox update
```

`SB_MIRRORS` 会完全覆盖内置列表。写进 `~/.zshrc` 可长期生效。

> 镜像的工作方式是**前缀拼接**：把完整的 GitHub 链接接在镜像域名后面。所以只要是这类代理站都能用，格式为 `https://镜像域名`，不要带尾部路径。

#### 实在都不通

手动下载内核，然后跳过版本查询：

```bash
# 在能联网的机器上下好，拷过来解压到 /usr/local/bin/sing-box
sudo install -m 755 ./sing-box /usr/local/bin/sing-box
sudo xattr -d com.apple.quarantine /usr/local/bin/sing-box
singbox install --config ./你的配置.json    # 检测到已安装会跳过下载
```

> **规则集下载是另一回事。** 那些走的是配置里的 `download_detour`（即代理本身），与这里的镜像无关。规则集不通时跑 `singbox rules` 排查。

### `uninstall`

移除服务、停用自启，逐项询问是否删除内核、是否删除配置目录。

**系统层设置会逐项询问是否还原**：DNS 按备份精确回滚，IPv6 恢复为自动。选择保留也可以——脚本会打印手动还原的命令。

**还会扫描并清理运行残留。** 配置里若有相对路径（Clash 面板的 `external_ui: "ui"`、`cache_file.path: "cache.db"`），前台运行时它们会落在**当时的工作目录**——常见于 `~/bin`、家目录，或你跑脚本时所在的位置。卸载时脚本会在这几处查找 `ui/` 和 `cache.db` 并询问删除。

> 你自己的源配置文件（如 `config.json`）不会被动——`install` 只读取它，卸载也不删。要清理请自行处理。
>
> 现在前台运行都会用 `-D` 固定工作目录到 `/usr/local/etc/sing-box`，新的残留不会再产生。

---

## 9. 边界情况的处理

这些是脚本内部做的防护，知道了出问题时更好判断：

**并发保护。** 用锁目录防止两个实例同时改配置或加载服务。发现锁属于已死进程会自动清理。

**绝不 `kill -9`。** 正常退出时 sing-box 会拆掉 utun 并还原路由表；强杀留下残留路由，症状是断网且看不出原因。脚本一律 SIGTERM，等待 8 秒，超时只警告不强杀。

**用 `bootstrap` / `bootout`，不用 `load` / `unload`。** 后者是遗留接口，报错含糊——`Load failed: 5: Input/output error` 几乎不给线索。

**内核安装失败会回滚。** 装新版前备份旧二进制，新版跑不起来就换回去。

**配置永远不被就地破坏。** `install` 用工作副本处理，`edit` 校验不过不写入且保留你的修改，覆盖前一定备份。

**GitHub 不可达时自动换镜像。** 下载与版本查询都是"直连 → 记住的镜像 → 内置列表"逐级回退，成功的镜像会被记住但不会取代直连的优先级。全都不通才报错，并给出手动下载的出路。

**非交互友好。** `-y` 全取默认，管道里运行（非 tty）也自动取默认，不会卡在等输入。

**只读操作不要 sudo。** `verify`、`syscheck`、`rules` 全程无需管理员权限。

**`--help` 在任何系统上都能看。** 平台检查放在参数解析之后。

---

## 10. 常见问题

**Q：`install` 中途失败了，能重跑吗**
能，且是安全的。已安装的内核会询问是否重装，已存在的配置会先备份，已加载的服务会先 `bootout`。

**Q：`verify` 第 1 步就失败**
SOCKS 不通说明问题在节点本身，与 TUN、路由规则无关。逐字符比对 `uuid`、`server_name`(SNI)、`public_key`、`short_id`，确认 `flow` 两端一致、Mux 已关。**这一步不过，后面的结果都没有参考价值。**

**Q：`verify` 第 2 步两个 IP 相同**
服务端问题——按 UUID 分流没生效，或 vpsre 的中转链路断了。客户端配置怎么改都没用。也可能是 `ipinfo.io` 没命中社交组，用 `debug` 确认。

**Q：`verify` 退出 2，但看着好像也没坏**
退出 2 是**策略档**失败：DNS、QUIC、国内直连里至少有一项没生效。它不影响"能不能上网"，
所以体感上像没坏，但你正在失去的恰恰是分流本身——比如国内流量全绕道代理、或者 QUIC 绕开了
规则表直接出网。按打 `✗` 的那一步去查配置：跑 `rules` 确认规则集下来了，跑 `debug` 看连接
落在哪个出站。`update` 遇到退出 2 不会回滚，因为换内核修不了这类问题。

**Q：`verify` 报「本机没有可用解析手段」**
不是 DNS 被污染，是 `dig` / `host` / `dscacheutil` / `python3` 四条路都没拿到 A 记录——
先确认这台机器现在能不能上网，再看 `syscheck` 里系统 DNS 是不是被设成了内网地址。

**Q：装在别的位置**
`--prefix ~/singbox-local`。注意 plist 里的路径会跟着变，卸载重装时前缀要一致。

**Q：Apple Silicon 能用吗**
能，自动判断，不需要手动指定。

判据是硬件（`sysctl -n hw.optional.arm64`），**不是 `uname -m`**。
`uname -m` 报的是当前**进程**的架构：在 Rosetta 方式打开的终端、x86_64 的 Homebrew bash、
或 `arch -x86_64 bash` 里，它会说 `x86_64`。早先按它判断，会在 ARM 机器上装 Intel 内核——
一个常驻的网络路径守护进程被塞进翻译层，而且 `update` 走同一个函数，会把这个错误一直续下去。

检测到当前 shell 被翻译时，`install` 会明说，并提示用 `arch -arm64 zsh` 开一个原生 shell。
要覆盖自动判断仍可用 `--arch`。

**Q：`update` 说 GitHub 与所有镜像均不可达**
先 `singbox mirror test` 看是哪一层的问题。代理能跑的话先 `start` 让它工作，直连往往就通了。内置镜像全挂就用 `SB_MIRRORS` 指定自己的，或按 `mirror` 一节手动下载内核。

**Q：每次都要输密码**
`sudo` 凭据默认几分钟过期，脚本在长任务期间会自动续期。连续操作时先跑一次 `sudo -v` 预热。**不建议给脚本配免密 sudo**——它能改路由表和网络配置。

**Q：能定时跑 `verify` 做健康检查吗**
可以，但它会发若干次外网请求。轻量的健康检查用 `status` 更合适。
