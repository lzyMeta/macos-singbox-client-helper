# macos-singbox-client-helper

在 macOS 上把 sing-box 作为系统服务直接运行的**客户端**配置方案与管理脚本。

一份可直接用的双节点分流配置、一个覆盖安装到卸载全流程的管理脚本，外加一份把每个字段"为什么这么写"讲清楚的文档。

> **只负责客户端。** 服务端节点请自行搭建，本仓库不涉及服务端配置。

---

## 目录

- [1. 这是什么](#1-这是什么)
- [2. 快速开始](#2-快速开始)
- [3. 管理脚本 singbox.sh](#3-管理脚本-singboxsh)
- [4. 文档](#4-文档)
- [5. 仓库结构](#5-仓库结构)
- [6. 许可](#6-许可)

---

## 1. 这是什么

### 双节点的分工

方案使用两条 **VLESS + REALITY + Vision** 节点：

| 节点 | 出口 | 承接什么 |
|---|---|---|
| `vpstrans` | 机房 IP | 大部分流量：AI 服务、开发工具、以及未被规则命中的兜底 |
| `vpsre` | 住宅 IP | 对 IP 纯净度要求高的场景：社交类应用 |

**两条节点的地址、端口、REALITY 参数完全相同，只有 UUID 不同。** 客户端都连 `vpstrans`，服务端按 UUID 决定是本机出网还是转发到住宅节点。这样客户端只需维护一个入口，住宅节点也不必直接暴露。

```
App → utun 虚拟网卡 → 嗅探（还原域名）→ DNS 劫持 → 路由规则匹配
                                                    ├─ reject   → 丢弃
                                                    ├─ direct   → 物理网卡
                                                    ├─ vpstrans → REALITY(UUID·A) → 机房 IP 出网
                                                    └─ vpsre    → REALITY(UUID·B) → vpstrans 中转 → 住宅 IP 出网
```

### 方案覆盖的要点

- **TUN 全局接管**，不依赖系统代理
- **全链路禁用 IPv6**（系统接口 + TUN + DNS 三层）
- **DNS 防泄漏**：境内外解析分流，两端都走 DoH
- **禁用 QUIC**、广告拦截、局域网直连
- 按域名分流：AI / 工具 → `vpstrans`，社交 → `vpsre`，中国域名与 IP → 直连

### 适用环境

- macOS，Intel 与 Apple Silicon 都可以（架构自动判断，按硬件而非 `uname -m`，所以 Rosetta 下的 shell 也不会选错）
- **只有 macOS。** Windows 与 Linux 不在支持范围，也不打算支持：服务管理靠 launchd、网络与 DNS 靠 `networksetup` / `scutil`、配置校验靠 `plutil`，换平台等于另写一个程序。在非 macOS 上运行会点名当前系统并说明缺什么，然后退出
- sing-box **1.12 / 1.13 / 1.14**（1.11 及更早的 DNS 格式不同，配置不兼容）
- 本机代理场景，非软路由

### 不包含什么

- **服务端搭建。** 两条节点、UUID 分流、住宅节点中转都在服务端，请自行配置。
- **节点参数。** 配置里全是占位符，需要你填自己的地址、SNI、公钥、UUID。

---

## 2. 快速开始

```bash
git clone https://github.com/lzyMeta/macos-singbox-client-helper.git
cd macos-singbox-client-helper && chmod +x singbox.sh
cp config/config.example.json config.json && $EDITOR config.json   # 换掉 7 个 YOUR_ 占位符
./singbox.sh -n install --config ./config.json                     # 空跑
./singbox.sh install --config ./config.json                        # 真装，要管理员密码
```

装完 `singbox` 命令全局可用（`/usr/local/bin/singbox`），`update` 会连它一起升级。
占位符怎么填、八个安装步骤各做什么、装完还要关浏览器 DoH——见 **[首次安装](docs/manual-install.md)**。

---

## 3. 管理脚本 `singbox.sh`

覆盖安装、配置、验证、运行、排查、升级、卸载的全生命周期，22 个子命令。

| 分类 | 命令 |
|---|---|
| 安装 | `install` `sysprep` |
| 运行 | `status` `start` `stop` `restart` `enable` `disable` `logs` |
| 检查 | `verify` `syscheck` `rules` `debug` `doctor` |
| 配置 | `edit` `config`（含 `config audit`） `dns` |
| 维护 | `update` `rollback` `mirror` `uninstall` |

> `update` 升级的是**脚本与内核两样**；`rollback` 也是两样一起退。

几个值得单独知道的：

- **`verify`** 六步验证，**没有任何一步会被静默跳过**——退出码 `0` 全过、`1` 链路档失败（换内核可能修好）、`2` 仅策略档失败（DNS/QUIC/国内直连，回滚换不回来，`update` 不会因此回滚）。**第 2 步最关键**：两个出口 IP 必须不同——日志只能证明"流量派给了 `vpsre` 出站"，证明不了它的出口真是住宅 IP（那段中转在服务端，客户端看不见）。这是客户端侧唯一能发现中转断掉的手段。
- **`config audit`** 审查配置里的废弃字段与不合法之处，用的是当前装着的那个内核。退出码 `0` 干净、`2` 有废弃项但现在还能跑、`1` 内核已经不接受。`--apply` 能自动改掉三类常见废弃写法（改前备份，改后四道验收，不过就不落地）；`--deep` 起一次沙箱收内核运行时的告警（要网络）。升级内核前跑一次。
- **`syscheck`** 最容易忘、也最该记住。IPv6 与 DNS 设置**按网络服务生效、不会继承**——插网卡、连手机热点、公司 VPN 退出没还原 DNS，都会留下缺口，而代理看起来一切正常。
- **`doctor`** 出问题先跑它，自动判读十类常见故障并输出诊断文件（写在 0700 的临时目录里 —— 里面有你访问过的域名与日志，贴出来之前先看一眼）。
- **`edit`** 改配置走"校验 → 备份 → 重启"，两关都过才写入，不过则保留你的修改到临时文件。
- **`dns`** 查看与切换系统 DNS。停服后 `1.1.1.1` 的明文查询在国内同样会被污染，所以 `stop` / `disable` / `uninstall` 会询问是否交回 DHCP。

每个命令怎么用、出错看哪，见第 4 节的五份操作手册。

### 脚本遵循的几条规矩

- **绝不 `kill -9`**：强杀会留下残留路由，症状是断网且看不出原因。
- **用 `bootstrap` / `bootout` 而非 `load` / `unload`**：后者报错含糊，`Load failed: 5: Input/output error` 几乎不给线索。
- **改配置前一定备份**，带时间戳，自动保留最近 10 份。
- **升级先换脚本再换内核**：`update` 的阶段 S 先把 `/usr/local/bin/singbox` 更新到最新 release 再继续 —— 历史上出问题的恰恰是升级逻辑本身而不是内核。取不到新脚本只 warn，不阻断内核升级。
- **升级分四个阶段，每个阶段都能退回已知可用的状态**：阶段 1 把新内核装到临时前缀、用一份去掉 `tun`、改了端口的**派生配置**实跑并实测建链——现网服务全程不受影响；到阶段 2 才动 `/usr/local/bin/sing-box`，起不来就回滚；阶段 3 跑一遍 `verify` 六步验收。
- **`rollback` 是随时能按的按钮**：升级成功后旧内核保留在 `sing-box.prev`，当时一切正常、半小时后才发现某个网站进不去，一条命令换回去。只保留一份，只能退一步。
- **只读命令不要 sudo**：`verify`、`syscheck`、`rules` 全程无需管理员权限。

改动脚本后跑 `./singbox-selfcheck.sh && ./tests/run.sh`。前半段是静态自检（13 项），覆盖几类 macOS 特有的坑（bash 3.2 的变量解析与 `shift 2` 的参数消耗、BSD `mktemp` 的模板限制、`set -u` 下的空数组展开等）；后半段是 `tests/` 下的测试文件（清单见第 5 节），用 PATH 前置的桩把脚本整个跑一遍——离线、不要 sudo、不碰真实系统。

自检的每一项在 `tests/fixtures/` 里都有「会被抓到」和「不该被抓到」两种样本钉住。这不是形式主义：曾经有 2 项用了 GNU 专有的 `grep -P`，在 BSD grep 上恒报错、永远不绿；也曾有 1 项的正则只匹配恰好 2 空格缩进，于是恒绿、永远不报。两种坏法都不会自己暴露。

---

## 4. 文档

**操作手册**（只讲怎么做，每份不超过 120 行）：

| 手册 | 覆盖的命令 |
|---|---|
| [首次安装](docs/manual-install.md) | `install` `sysprep` |
| [日常运行](docs/manual-daily.md) | `status` `start` `stop` `restart` `enable` `disable` `dns` `logs` |
| [检查与排查](docs/manual-check.md) | `verify` `syscheck` `rules` `debug` `doctor` |
| [改配置与配置审查](docs/manual-config.md) | `edit` `config`（含 `config audit`） |
| [升级、回退与卸载](docs/manual-update.md) | `update` `rollback` `mirror` `uninstall` |

**方案与原理**：

| 文档 | 读它干什么 |
|---|---|
| **[docs/best-practices.md](docs/best-practices.md)** | 为什么这么配。配置逐字段详解、系统层准备、验证清单、故障排查、脚本的设计取舍 |
| [docs/maintaining.md](docs/maintaining.md) | 维护者手册：验收、文档怎么不漂移、迁移表怎么更新 |

`best-practices.md` 里几个容易踩的点：

- **DNS 层为什么拦 AAAA 用 `NOERROR` 而拦广告用 `NXDOMAIN`**——用反了会把正常网站也弄挂
- **规则集内部不是顺序匹配**，外层规则表才是；由此带来"无法在规则集内部做排除"的限制
- **IP 规则匹配不到域名连接**，以及本方案刻意不插 `resolve` 的取舍
- **规则集下载失败不会阻止启动**，只静默让规则永不命中——最隐蔽的一类故障
- **系统 DNS 若是路由器地址，查询根本不进 TUN**，明文出网被投毒

**设计记录**（按时间；写的是当时的问题与决定，不随代码更新，行号与数字以代码为准）：

| 记录 | 内容 |
|---|---|
| [docs/safe-update.md](docs/safe-update.md) | `update` 重做为四阶段 + `rollback` |
| [docs/verify-hardening.md](docs/verify-hardening.md) | `verify` 消除静默跳过，两档退出码 |
| [docs/self-install-and-self-update.md](docs/self-install-and-self-update.md) | `install` 装 `singbox` 命令，`update` 阶段 S 脚本自更新 |
| [docs/config-audit-and-modernize.md](docs/config-audit-and-modernize.md) | `config audit` 第一轮：两路发现层 + `--apply` |
| [docs/config-audit-migration-table.md](docs/config-audit-migration-table.md) | `config audit` 第二轮：四路发现层、迁移表、三条改写规则 |

---

## 5. 仓库结构

```
.
├── README.md                  本文件
├── LICENSE                    许可（个人使用）
├── singbox.sh                 管理脚本
├── singbox-selfcheck.sh       脚本静态自检
├── .github/workflows/
│   └── release.yml            /sdlc-kit:release 触发（workflow_dispatch）：校验 tag == VERSION，建 release 并传 singbox.sh
├── tests/
│   ├── run.sh                 跑 tests/ 下所有 *.test.sh
│   ├── cli.test.sh            参数解析
│   ├── selfcheck.test.sh      验证自检项真的在检查
│   ├── install.test.sh        install 把脚本装成 $PREFIX/bin/singbox
│   ├── selfupdate.test.sh     update 阶段 S（脚本自更新）的状态机
│   ├── update.test.sh         update / rollback 的状态机断言
│   ├── logs.test.sh           日志体积可见性与原地截断
│   ├── platform.test.sh       平台与 CPU 架构判定（Rosetta）
│   ├── verify.test.sh         verify 的两档退出码
│   ├── config-audit.test.sh   config audit 的发现层、迁移表与 --apply
│   ├── doctor.test.sh         doctor / status 对 TUN 路由的判读
│   ├── template.test.sh       config.example.json 过 audit、且与 live 逐键一致
│   ├── docs.test.sh           手册对着源头核对（子命令、文件清单、目录、配置全文…）
│   └── fixtures/              样本脚本与 PATH 桩（假 sudo / curl / launchctl 等）
├── config/
│   └── config.example.json    配置模板（占位符）
└── docs/
    ├── manual-install.md      操作手册：首次安装
    ├── manual-daily.md        操作手册：日常运行
    ├── manual-check.md        操作手册：检查与排查
    ├── manual-config.md       操作手册：改配置与配置审查
    ├── manual-update.md       操作手册：升级、回退与卸载
    ├── best-practices.md      方案文档与字段详解
    ├── maintaining.md         维护者手册
    ├── safe-update.md         设计记录：update 四阶段 + rollback
    ├── verify-hardening.md    设计记录：verify 收紧
    ├── self-install-and-self-update.md
    │                          设计记录：singbox 命令自动安装与脚本自更新
    ├── config-audit-and-modernize.md
    │                          设计记录：config audit 第一轮
    └── config-audit-migration-table.md
                               设计记录：config audit 第二轮（迁移表）
```

`.gitignore` 已排除 `config.json`、`*.bak`、`ui/`、`cache.db` 等本地产物——**填好参数的配置不要提交**。

---

## 6. 许可

**仅限个人使用。** 见 [LICENSE](LICENSE)。

允许个人下载、使用、修改；不允许商业使用、再分发或作为服务提供。这不是 OSI 意义上的开源许可，GitHub 也不会将其识别为标准协议。

---

## 免责声明

本仓库仅提供客户端配置与管理工具。使用者需自行确保其使用方式符合所在地区的法律法规。作者不对使用本仓库内容产生的任何后果负责。
