# macos-singbox-client-helper

在 macOS 上把 sing-box 作为系统服务直接运行的**客户端**配置方案与管理脚本。

一份可直接用的双节点分流配置、一个覆盖安装到卸载全流程的管理脚本，外加一份把每个字段"为什么这么写"讲清楚的文档。

> **只负责客户端。** 服务端节点请自行搭建，本仓库不涉及服务端配置。

---

## 目录

- [1. 这是什么](#1-这是什么)
- [2. 下载与安装](#2-下载与安装)
- [3. 管理脚本 singbox.sh](#3-管理脚本-singboxsh)
- [4. 方案文档](#4-方案文档)
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

- macOS（在 Intel 机型上开发与验证；Apple Silicon 加 `--arch arm64`）
- sing-box **1.12 / 1.13 / 1.14**（1.11 及更早的 DNS 格式不同，配置不兼容）
- 本机代理场景，非软路由

### 不包含什么

- **服务端搭建。** 两条节点、UUID 分流、住宅节点中转都在服务端，请自行配置。
- **节点参数。** 配置里全是占位符，需要你填自己的地址、SNI、公钥、UUID。

---

## 2. 下载与安装

### 2.1 获取

```bash
git clone https://github.com/lzyMeta/macos-singbox-client-helper.git
cd macos-singbox-client-helper
chmod +x singbox.sh
```

从浏览器下载 zip 的话，先解除隔离标记：

```bash
xattr -dr com.apple.quarantine .
```

### 2.2 填写配置

```bash
cp config/config.example.json config.json
$EDITOR config.json
```

需要替换的占位符：

| 占位符 | 说明 |
|---|---|
| `YOUR_VPSTRANS_ADDR` | vpstrans 的 IP 或域名（两条节点都连它） |
| `YOUR_SNI` | REALITY 的 SNI，与服务端 dest 一致 |
| `YOUR_PUBLIC_KEY` | 服务端 REALITY 公钥 |
| `YOUR_SHORT_ID` | 服务端签发的 short ID |
| `YOUR_UUID_VPSTRANS` | 走机房出口的 UUID |
| `YOUR_UUID_VPSRE` | 走住宅出口的 UUID |
| `YOUR_CLASH_SECRET` | Clash 面板的访问口令，换成一串随机字符 |

两个 UUID 必须是标准的 `8-4-4-4-12` 格式。脚本会在安装的第一步检查是否还有未替换的占位符。

### 2.3 安装

```bash
./singbox.sh -n install --config ./config.json    # 先空跑，看会做什么
./singbox.sh install --config ./config.json       # 真正执行
```

需要管理员密码：TUN 建虚拟网卡、改路由表必须 root。

安装流程共七步：环境检查 → 装内核 → **系统层准备** → 放置配置 → 静态校验 → 前台试跑 → 装服务 → 自动验证。

> **第三步不能跳。** 关闭 IPv6、把系统 DNS 指向非局域网地址、退掉其他 VPN——这三件事配置文件管不了，不做的话后面验证一定过不去，而症状完全不指向真正的原因。

### 2.4 装完之后

```bash
./singbox.sh status     # 服务、TUN 路由、监听端口
./singbox.sh verify     # 完整验证清单
./singbox.sh rules      # 验证规则集 URL 是否可达
```

还有一件脚本做不了的事：**关闭浏览器的内置 DoH**。Chrome 在 `chrome://settings/security` 关闭「使用安全 DNS」，Firefox 在 `about:config` 把 `network.trr.mode` 设为 `5`。不关的话它会绕过系统 DNS，典型症状是 Google 打不开而别的站正常。

### 2.5 把脚本装进 PATH（可选）

```bash
mkdir -p ~/bin && cp singbox.sh ~/bin/singbox && chmod +x ~/bin/singbox
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

之后全局可用 `singbox <命令>`。

---

## 3. 管理脚本 `singbox.sh`

覆盖安装、配置、验证、运行、排查、升级、卸载的全生命周期，22 个子命令。

| 分类 | 命令 |
|---|---|
| 安装 | `install` `sysprep` |
| 运行 | `status` `start` `stop` `restart` `enable` `disable` `logs` |
| 检查 | `verify` `syscheck` `rules` `debug` `doctor` |
| 配置 | `edit` `config` `dns` |
| 维护 | `update` `rollback` `mirror` `uninstall` |

几个值得单独知道的：

- **`verify`** 五步验证，**没有任何一步会被静默跳过**——退出码 `0` 全过、`1` 链路档失败（换内核可能修好）、`2` 仅策略档失败（DNS/QUIC/国内直连，回滚换不回来，`update` 不会因此回滚）。**第 2 步最关键**：两个出口 IP 必须不同——日志只能证明"流量派给了 `vpsre` 出站"，证明不了它的出口真是住宅 IP（那段中转在服务端，客户端看不见）。这是客户端侧唯一能发现中转断掉的手段。
- **`syscheck`** 最容易忘、也最该记住。IPv6 与 DNS 设置**按网络服务生效、不会继承**——插网卡、连手机热点、公司 VPN 退出没还原 DNS，都会留下缺口，而代理看起来一切正常。
- **`doctor`** 出问题先跑它，自动判读九类常见故障并输出诊断文件。
- **`edit`** 改配置走"校验 → 备份 → 重启"，两关都过才写入，不过则保留你的修改到临时文件。
- **`dns`** 查看与切换系统 DNS。停服后 `1.1.1.1` 的明文查询在国内同样会被污染，所以 `stop` / `disable` / `uninstall` 会询问是否交回 DHCP。

完整说明见 **[docs/script-usage.md](docs/script-usage.md)**。

### 脚本遵循的几条规矩

- **绝不 `kill -9`**：强杀会留下残留路由，症状是断网且看不出原因。
- **用 `bootstrap` / `bootout` 而非 `load` / `unload`**：后者报错含糊，`Load failed: 5: Input/output error` 几乎不给线索。
- **改配置前一定备份**，带时间戳，自动保留最近 10 份。
- **升级分四个阶段，每个阶段都能退回已知可用的状态**：阶段 1 把新内核装到临时前缀、用一份去掉 `tun`、改了端口的**派生配置**实跑并实测建链——现网服务全程不受影响；到阶段 2 才动 `/usr/local/bin/sing-box`，起不来就回滚；阶段 3 跑一遍 `verify` 五步验收。
- **`rollback` 是随时能按的按钮**：升级成功后旧内核保留在 `sing-box.prev`，当时一切正常、半小时后才发现某个网站进不去，一条命令换回去。只保留一份，只能退一步。
- **只读命令不要 sudo**：`verify`、`syscheck`、`rules` 全程无需管理员权限。

改动脚本后跑 `./singbox-selfcheck.sh && ./tests/run.sh`。前半段是静态自检，覆盖几类 macOS 特有的坑（bash 3.2 的变量解析、BSD `mktemp` 的模板限制、`set -u` 下的空数组展开等）；后半段是 `tests/`，用 PATH 前置的桩把 `update` / `rollback` 的状态机整个跑一遍——离线、不要 sudo、不碰真实系统。

---

## 4. 方案文档

**[docs/best-practices.md](docs/best-practices.md)** 讲的是"为什么这么配"，不只是"怎么配"：

| 章节 | 内容 |
|---|---|
| 0 | 架构与关键决策 |
| 1 | 完整配置 JSON |
| 2 | **配置逐字段详解**——每个字段是什么、为什么这么写、版本兼容对照 |
| 3–4 | 安装内核、macOS 系统层准备 |
| 5 | 验证清单，每步都有"不通过时"分支 |
| 6 | 运行与开机自启 |
| 7 | 故障排查 |
| 8 | 安全与维护 |

几个文档里展开讲的、容易踩的点：

- **DNS 层为什么拦 AAAA 用 `NOERROR` 而拦广告用 `NXDOMAIN`**——用反了会把正常网站也弄挂
- **规则集内部不是顺序匹配**，外层规则表才是；由此带来"无法在规则集内部做排除"的限制
- **IP 规则匹配不到域名连接**，以及本方案刻意不插 `resolve` 的取舍
- **规则集下载失败不会阻止启动**，只静默让规则永不命中——最隐蔽的一类故障
- **系统 DNS 若是路由器地址，查询根本不进 TUN**，明文出网被投毒

---

## 5. 仓库结构

```
.
├── README.md                  本文件
├── LICENSE                    许可（个人使用）
├── singbox.sh                 管理脚本
├── singbox-selfcheck.sh       脚本静态自检
├── tests/
│   ├── run.sh                 跑 tests/ 下所有 *.test.sh
│   ├── selfcheck.test.sh      验证自检项真的在检查
│   ├── update.test.sh         update / rollback 的状态机断言
│   └── fixtures/              样本脚本与 PATH 桩（假 sudo / curl / launchctl 等）
├── config/
│   └── config.example.json    配置模板（占位符）
└── docs/
    ├── script-usage.md        脚本使用说明
    └── best-practices.md      方案文档与字段详解
```

`.gitignore` 已排除 `config.json`、`*.bak`、`ui/`、`cache.db` 等本地产物——**填好参数的配置不要提交**。

---

## 6. 许可

**仅限个人使用。** 见 [LICENSE](LICENSE)。

允许个人下载、使用、修改；不允许商业使用、再分发或作为服务提供。这不是 OSI 意义上的开源许可，GitHub 也不会将其识别为标准协议。

---

## 免责声明

本仓库仅提供客户端配置与管理工具。使用者需自行确保其使用方式符合所在地区的法律法规。作者不对使用本仓库内容产生的任何后果负责。
