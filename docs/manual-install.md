---
kind: manual
covers:
  - config/config.example.json
---
# 首次安装

从零到代理跑起来：取脚本、填配置、`install`、验证。装完 `singbox` 命令全局可用。

## 前提

- macOS（Intel 或 Apple Silicon 都行，架构自动判断）
- 管理员密码：TUN 建虚拟网卡、改路由表必须 root
- 服务端两条节点的参数：地址、SNI、REALITY 公钥、short ID、两个 UUID

## 步骤

1. 取脚本

   ```bash
   git clone https://github.com/lzyMeta/macos-singbox-client-helper.git
   cd macos-singbox-client-helper
   chmod +x singbox.sh
   ```

   从浏览器下载 zip 的先解除隔离标记：`xattr -dr com.apple.quarantine .`。
   只要脚本不要仓库：`curl -fsSLO https://github.com/lzyMeta/macos-singbox-client-helper/releases/latest/download/singbox.sh`。

2. 填配置

   ```bash
   cp config/config.example.json config.json
   $EDITOR config.json
   ```

   | 占位符 | 换成 |
   |---|---|
   | `YOUR_VPSTRANS_ADDR` | vpstrans 的 IP 或域名（两条节点都连它） |
   | `YOUR_SNI` | REALITY 的 SNI，与服务端 dest 一致 |
   | `YOUR_PUBLIC_KEY` | 服务端 REALITY 公钥 |
   | `YOUR_SHORT_ID` | 服务端签发的 short ID |
   | `YOUR_UUID_VPSTRANS` | 走机房出口的 UUID |
   | `YOUR_UUID_VPSRE` | 走住宅出口的 UUID |
   | `YOUR_CLASH_SECRET` | Clash 面板口令，一串随机字符 |

   两个 UUID 必须是标准的 `8-4-4-4-12` 格式。

3. 先空跑，再安装

   ```bash
   ./singbox.sh -n install --config ./config.json    # 只打印将做什么
   ./singbox.sh install --config ./config.json       # 真正执行
   ```

   八步：环境与配置检查 → 装内核 → 装 `singbox` 命令到 `/usr/local/bin` → 系统层准备
   （关 IPv6、系统 DNS 指向 `1.1.1.1`、检测冲突的 VPN）→ 放置配置 → `sing-box check` →
   前台试跑 25 秒 → 装服务并自动 `verify`。可选参数：`--version <v>` 指定内核版本、
   `--arch amd64|arm64` 覆盖架构判断、`--force` 已安装时直接重装、`--prefix <dir>` 换安装位置。

4. 关闭浏览器内置 DoH——脚本做不了这件事

   ```text
   Chrome   chrome://settings/security → 关闭「使用安全 DNS」
   Firefox  about:config → network.trr.mode = 5
   ```

5. 验证

   ```bash
   singbox status     # 服务、TUN 路由、监听端口
   singbox verify     # 六步验证，退出 0 才算全过
   singbox rules      # 规则集 URL 是否可达
   ```

## 出错了看哪

- **报「配置里还有占位符」** → 第 2 步没填全。这个检查在下载内核之前，改完重跑即可。
- **`install` 中途失败** → 直接重跑，是安全的：已装的内核会问是否重装，已有配置先备份，已加载的服务先卸。
- **`verify` 第 1 步就失败** → 问题在节点参数，与 TUN、路由无关。逐字符比对 `uuid`、`server_name`、`public_key`、`short_id`，确认 `flow` 两端一致、Mux 已关。这一步不过，后面的结果没有参考价值。
- **`verify` 第 2 步两个出口 IP 相同** → 服务端按 UUID 分流没生效或住宅中转断了，客户端怎么改都没用。
- **Google 打不开、别的站正常** → 第 4 步的浏览器 DoH 没关。
- **每步都要输密码** → 先 `sudo -v` 预热。不要给脚本配免密 sudo，它能改路由表。
- **Apple Silicon 上装成了 Intel 内核** → 终端在 Rosetta 下运行；`install` 会提示，用 `arch -arm64 zsh` 开原生 shell 重装，或 `--arch arm64`。
- **以前手工放过 `~/bin/singbox`** → 自己删掉。新装的在 `/usr/local/bin`，PATH 里谁在前谁生效。
- 卸载：`singbox uninstall`，见 [升级、回退与卸载](manual-update.md)。

## 深入阅读

- [为什么用官方 release 不用 Homebrew](best-practices.md#31-用官方-release别用-homebrew)
- [系统层准备为什么不能跳](best-practices.md#4-macos-系统层准备不可跳过)
- [架构判定为什么不用 uname -m](best-practices.md#98-架构判定)
- [`singbox` 命令的自动安装与自更新（设计记录）](self-install-and-self-update.md)
