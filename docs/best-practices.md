# 在 macOS 上直接运行 sing-box —— 配置最佳实践

> 环境：MacBook Pro / Intel，本机代理（非软路由），macOS 26
> 目标：TUN 全局接管 + 全链路禁用 IPv6 + DNS 防泄漏 + VLESS-REALITY-Vision 双节点按域名分流
> 参考：sing-box 官方文档 `https://sing-box.sagernet.org/configuration/`
> 适用内核：**sing-box 1.12 / 1.13 / 1.14**（1.11 及更早的 DNS 格式不同，本文配置不兼容）

---

## 怎么读这份文档

| 你的目标 | 看哪几节 |
|---|---|
| 从零跑起来 | 3 → 4 → 1 → 5 → 6 |
| 只想拿配置 | 1 |
| 搞懂每个字段为什么这么写 | 2 |
| 验证配置对不对 | 5 |
| 出问题了 | 7 |

前两章是**配置本身**（是什么、为什么这么写），第 3、4 章是**动手前的环境准备**。如果你只想理解方案，读 1、2 就够；要真正跑起来，从第 3 章开始按顺序做。

**第 4 节不能跳。** 本方案有三件事必须在 macOS 系统层面做，配置文件管不了：关闭 IPv6、把系统 DNS 指向非局域网地址、退掉其他 VPN 客户端。这三件事没做，配置写得再对也会出现"能连但打不开""IPv6 没禁住""DNS 被投毒"这类问题——而且症状完全不指向真正的原因。

---

## 目录

- [0. 架构与取舍](#0-架构与取舍)
  - [0.1 数据流向](#01-数据流向)
  - [0.2 关键决策](#02-关键决策)
- [1. 配置全文](#1-配置全文)
- [2. 配置逐字段详解](#2-配置逐字段详解)
  - [2.1 顶层结构与 `log`](#21-顶层结构与-log)
  - [2.2 `dns`](#22-dns)
  - [2.3 `inbounds`](#23-inbounds)
  - [2.4 `outbounds`](#24-outbounds)
  - [2.5 `route` 顶层](#25-route-顶层)
  - [2.6 `route.rules[]` 与匹配语义](#26-routerules-与匹配语义)
  - [2.7 `route.rule_set[]`](#27-routerule_set)
  - [2.8 `experimental.cache_file`](#28-experimentalcache_file)
  - [2.9 版本兼容对照](#29-版本兼容对照)
- [3. 安装 sing-box](#3-安装-sing-box)
  - [3.1 用官方 release，别用 Homebrew](#31-用官方-release别用-homebrew)
  - [3.2 放置配置](#32-放置配置)
- [4. macOS 系统层准备（不可跳过）](#4-macos-系统层准备不可跳过)
  - [4.1 关闭 IPv6](#41-关闭-ipv6)
  - [4.2 把系统 DNS 指向非局域网地址](#42-把系统-dns-指向非局域网地址)
  - [4.3 退掉其他 VPN 客户端](#43-退掉其他-vpn-客户端)
  - [4.4 浏览器自带 DoH 要关掉](#44-浏览器自带-doh-要关掉)
- [5. 验证清单](#5-验证清单)
  - [5.1 静态校验（不启动内核）](#51-静态校验不启动内核)
  - [5.2 规则集验证](#52-规则集验证)
  - [5.3 连通性快测](#53-连通性快测)
  - [5.4 前台试跑](#54-前台试跑)
  - [5.5 服务与 TUN](#55-服务与-tun)
  - [5.6 先绕开 TUN 验证节点链路](#56-先绕开-tun-验证节点链路)
  - [5.7 系统层复查](#57-系统层复查)
  - [5.8 QUIC 与局域网](#58-quic-与局域网)
  - [5.9 出口 IP 与国内直连](#59-出口-ip-与国内直连)
- [6. 运行与开机自启](#6-运行与开机自启)
  - [6.1 LaunchDaemon](#61-launchdaemon)
  - [6.2 日常操作](#62-日常操作)
  - [6.3 三个必须知道的坑](#63-三个必须知道的坑)
  - [6.4 关于路由丢失](#64-关于路由丢失)
- [7. 故障排查](#7-故障排查)
  - [7.1 速查表](#71-速查表)
  - [7.2 端口被占用](#72-端口被占用)
  - [7.3 日志里出现 FakeIP 地址](#73-日志里出现-fakeip-地址)
  - [7.4 排查顺序建议](#74-排查顺序建议)
  - [7.5 服务加载失败](#75-服务加载失败)
  - [7.6 关于 `strict_route`](#76-关于-strict_route)
- [8. 安全与维护](#8-安全与维护)

---

## 0. 架构与取舍

### 0.1 数据流向

```
App → utun 虚拟网卡 → sniff（还原域名）→ DNS 劫持 → 路由规则匹配
                                                    ├─ reject   → 丢弃
                                                    ├─ direct   → 物理网卡
                                                    ├─ vpstrans → REALITY(UUID·A) → 机房 IP 出网
                                                    └─ vpsre    → REALITY(UUID·B) → vpstrans 中转 → 住宅 IP 出网
```

### 0.2 关键决策

| 决策点 | 结论 | 原因 |
|---|---|---|
| 运行方式 | launchd 系统服务（LaunchDaemon） | TUN 需要 root，用户级 LaunchAgent 拿不到 |
| 安装来源 | **官方 release 二进制**，不用 Homebrew | 见 3.1 |
| 两个节点 | 地址/端口/REALITY 参数完全相同，只有 UUID 不同 | 服务端按 UUID 决定本机出网还是转发到住宅 IP |
| IPv6 | 系统接口 + TUN + DNS 三层全关 | 未接管的 IPv6 绕过全部路由规则直连，是最隐蔽的泄漏面 |
| 协议栈 | `gvisor` | macOS 上兼容性最好；需内核带 `with_gvisor` 编译标签 |
| 兜底出站 | `vpstrans`（而非 direct） | 中国域名和 IP 已明确直连，未收录的境外站默认走代理，避免真实 IP 因漏网域名暴露 |
| FakeIP | **不用** | 能杜绝解析泄漏，但会破坏部分 macOS 原生 App 和局域网发现，本机代理场景收益不大 |

---

## 1. 配置全文

需要替换的占位符：`YOUR_VPSTRANS_ADDR`、`YOUR_SNI`、`YOUR_PUBLIC_KEY`、`YOUR_SHORT_ID`、`YOUR_UUID_VPSTRANS`、`YOUR_UUID_VPSRE`、`YOUR_CLASH_SECRET`。

> 两个 UUID 必须换成标准的 8-4-4-4-12 格式。

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "detour": "vpstrans"
      },
      {
        "type": "https",
        "tag": "dns-direct",
        "server": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "query_type": [
          "AAAA",
          "HTTPS"
        ],
        "action": "predefined",
        "rcode": "NOERROR"
      },
      {
        "rule_set": [
          "geosite-category-ads-all"
        ],
        "action": "predefined",
        "rcode": "NXDOMAIN"
      },
      {
        "rule_set": [
          "geosite-cn",
          "geosite-apple-cn",
          "geosite-microsoft-cn"
        ],
        "server": "dns-direct"
      }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only",
    "disable_expire": false
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "utun233",
      "address": [
        "172.19.0.1/30"
      ],
      "mtu": 9000,
      "auto_route": true,
      "strict_route": false,
      "stack": "gvisor"
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vpstrans",
      "server": "YOUR_VPSTRANS_ADDR",
      "server_port": 443,
      "uuid": "YOUR_UUID_VPSTRANS",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "domain_resolver": {
        "server": "dns-direct",
        "strategy": "ipv4_only"
      },
      "tls": {
        "enabled": true,
        "server_name": "YOUR_SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "YOUR_PUBLIC_KEY",
          "short_id": "YOUR_SHORT_ID"
        }
      }
    },
    {
      "type": "vless",
      "tag": "vpsre",
      "server": "YOUR_VPSTRANS_ADDR",
      "server_port": 443,
      "uuid": "YOUR_UUID_VPSRE",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "domain_resolver": {
        "server": "dns-direct",
        "strategy": "ipv4_only"
      },
      "tls": {
        "enabled": true,
        "server_name": "YOUR_SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "YOUR_PUBLIC_KEY",
          "short_id": "YOUR_SHORT_ID"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct",
      "domain_resolver": {
        "server": "dns-direct",
        "strategy": "ipv4_only"
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "dns-direct",
      "strategy": "ipv4_only"
    },
    "final": "vpstrans",
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "domain_suffix": [
          "local",
          "localhost",
          "lan",
          "home",
          "home.arpa",
          "arpa"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": [
          "geosite-private"
        ],
        "outbound": "direct"
      },
      {
        "network": "udp",
        "port": 443,
        "action": "reject"
      },
      {
        "rule_set": [
          "geosite-category-ads-all"
        ],
        "action": "reject"
      },
      {
        "rule_set": [
          "geosite-anthropic",
          "geosite-openai",
          "geosite-category-ai-!cn"
        ],
        "outbound": "vpstrans"
      },
      {
        "rule_set": [
          "geosite-github",
          "geosite-google",
          "geosite-bing"
        ],
        "outbound": "vpstrans"
      },
      {
        "domain_suffix": [
          "ttcdn-us.com",
          "ttlivecdn.com",
          "ttoverseaus.net",
          "ttwstatic.com",
          "ipinfo.io"
        ],
        "outbound": "vpsre"
      },
      {
        "rule_set": [
          "geosite-tiktok",
          "geosite-meta",
          "geosite-x",
          "geosite-telegram",
          "geosite-discord",
          "geosite-whatsapp"
        ],
        "outbound": "vpsre"
      },
      {
        "rule_set": [
          "geoip-telegram"
        ],
        "outbound": "vpsre"
      },
      {
        "rule_set": [
          "geosite-apple-cn",
          "geosite-microsoft-cn"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": [
          "geosite-gfw",
          "geosite-geolocation-!cn"
        ],
        "outbound": "vpstrans"
      },
      {
        "rule_set": [
          "geosite-cn",
          "geoip-cn"
        ],
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-private",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/private.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-category-ads-all",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-anthropic",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/anthropic.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-openai",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-category-ai-!cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ai-!cn.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-github",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-google",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-bing",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/bing.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-tiktok",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/tiktok.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-telegram",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/telegram.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-meta",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/meta.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-x",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/x.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-discord",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/discord.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-whatsapp",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/whatsapp.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geoip-telegram",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-apple-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/apple@cn.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-microsoft-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/microsoft@cn.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-gfw",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-geolocation-!cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geosite-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
        "download_detour": "vpstrans",
        "update_interval": "7d"
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/usr/local/etc/sing-box/cache.db",
      "store_fakeip": false
    }
  }
}
```

---

## 2. 配置逐字段详解

本节讲"每个字段是什么、为什么这么写"。依据官方文档 `https://sing-box.sagernet.org/configuration/`。

### 2.1 顶层结构与 `log`

官方定义的顶层键有 `log` / `dns` / `ntp` / `certificate` / `endpoints` / `inbounds` / `outbounds` / `route` / `services` / `experimental` 等，本配置用到五个。

`config/config.example.json` 顶层带一行 `"$schema": "https://sing-box.sagernet.org/schema.json"`：
这是给手写配置的人用的——VS Code 之类的编辑器读到它就能补全字段名、对拼错的键画红线。
它本身不是 sing-box 的配置项，内核 1.14.0 的 `check` 与 `schema` 都把它当合法顶层键接受
（`option/options.go:17`），所以 `config audit` 不会报它。它也**不会**被 `config audit` 建议引入：
「建议加 X」是策略，审查只管合法性。想要就抄这一行，不想要删掉也没有任何影响。

| `log` 字段 | 值 | 说明 |
|---|---|---|
| `level` | `info` | 级别：`trace` `debug` `info` `warn` `error` `fatal` `panic`。排查分流问题时临时调 `debug`，能看到每条连接命中了哪条规则 |
| `timestamp` | `true` | 排查时间相关问题（如睡眠唤醒）时必须有 |

### 2.2 `dns`

#### `dns.servers[]` — 定义解析器

| 字段 | 说明 |
|---|---|
| `type` | 解析器类型。本配置用 `https`（DoH）。另有 `udp` `tcp` `tls` `quic` `h3` `local` `hosts` `fakeip` 等 |
| `tag` | 名字，供 `dns.rules[].server`、`dns.final`、`domain_resolver.server` 引用，必须唯一 |
| `server` | 解析器地址。**刻意填 IP 而非域名**，见下 |
| `detour` | 这条查询走哪个出站。防泄漏的关键字段 |

本配置两个：`dns-remote` = `1.1.1.1` over DoH 走 `vpstrans`（境外域名）；`dns-direct` = `223.5.5.5` over DoH 走 `direct`（国内域名）。两条都是加密的，运营商 DNS 拿不到任何查询记录。

**为什么不写成 `https://dns.google/dns-query` 这类域名形式**：

1. **bootstrap 的鸡蛋问题，且解析结果不可信。** 写域名就得先解析 `dns.google` 本身，用的是 `route.default_domain_resolver`（本配置是国内 DoH）。而 `dns.google` / `cloudflare-dns.com` 在国内是重点污染对象，拿回来很可能是假 IP。虽然连接走 `detour` 出去，但目标 IP 已经错了，TLS 校验必然失败 → 远程 DNS 直接瘫痪，症状是"代理连得上但什么网站都打不开"。
2. **写两个 DoH 不会自动故障转移。** `rules[].server` 是单值、`final` 也只能指一个 tag，没有 mihomo 那种 fallback/竞速机制。

想要冗余就仍用 IP 字面量加第二个 tag：

```json
{ "type": "https", "tag": "dns-remote",  "server": "1.1.1.1", "detour": "vpstrans" },
{ "type": "https", "tag": "dns-remote2", "server": "8.8.8.8", "detour": "vpstrans" }
```

`1.1.1.1` 和 `8.8.8.8` 的证书都签了 IP SAN，用 IP 直连 DoH 校验能过。哪条不通了改 `final` 重启即可。顺带一提，`1.1.1.1` 本身就是 anycast，"用域名能拿多个 A 记录做负载"这个优势并不存在。

#### `dns.rules[]` — 决定谁用哪个解析器

自上而下匹配，**第一条命中即停**。同一条规则内，同字段多值是"或"，不同字段之间是"与"。

| `action` | 含义 |
|---|---|
| `route`（默认） | 转给 `server` 指定的解析器 |
| `route-options` | 不改变目标解析器，只调整本次查询的选项 |
| `reject` | 拒绝。`method: default` 回 REFUSED，`method: drop` 直接丢弃 |
| `predefined` | 不发查询，直接返回写好的应答。配 `rcode` 使用 |

官方支持的 `rcode`：`NOERROR` `FORMERR` `SERVFAIL` `NXDOMAIN` `NOTIMP` `REFUSED`。

**本配置三条规则**

1. `query_type: ["AAAA","HTTPS"]` + `predefined` + `NOERROR`
   不查询，直接回"成功但无记录"。
   **为什么是 `NOERROR` 而不是 `NXDOMAIN`**：`NOERROR` 的语义是"域名存在，只是没有这类记录"，应用会回退到 IPv4；`NXDOMAIN` 是"域名不存在"，部分应用据此判定整个域名不可用，连 A 记录都不再问，正常网站也会打不开。
   拦 `HTTPS`（SVCB/HTTPS 记录）是因为它携带 IPv6 hint 与 ALPN，浏览器可能据此直接发起 IPv6 或 HTTP/3 连接，绕过前两道防线。

2. `rule_set: geosite-category-ads-all` + `predefined` + `NXDOMAIN`
   广告域名在解析阶段就判"不存在"。这里**反过来要用 `NXDOMAIN`**，目的就是让应用彻底放弃。
   它与路由层的广告 `reject` 是两道独立防线：DNS 层拦下连接根本不会发起；路由层兜底应用绕过系统 DNS 或硬编码 IP 的情况。

3. `rule_set: [geosite-cn, geosite-apple-cn, geosite-microsoft-cn]` + `server: dns-direct`
   国内域名交给国内 DoH。**这是分流准确性的地基**：国内站点必须由国内解析器解析才能拿到就近 CDN 的 IP，路由层的 `geoip-cn` 才匹配得上。若被境外 DNS 解析，返回境外节点 IP，`geoip-cn` 不命中，流量被兜底送去代理——症状是淘宝、B 站特别慢，极易误判成节点问题。

> **一条必须记住的规律**：`dns.rules` 里判为国内解析的集合，和 `route.rules` 里判为 `direct` 的集合，应当是**同一个集合**。改动其中一边，另一边必须同步。这是这类配置最高频的错误来源，而且大部分情况下不报错、只是变慢。

#### `dns` 顶层字段

| 字段 | 本配置 | 说明 |
|---|---|---|
| `final` | `dns-remote` | 都没命中时用哪个解析器。设成境外解析是**防泄漏兜底**：未知域名宁可绕一圈也不交给本地 DNS |
| `strategy` | `ipv4_only` | 默认解析策略。与第 1 条规则重复设防 |
| `disable_expire` | `false` | 遵守 TTL。设 `true` 会让记录永不过期，CDN 调度变更后会连到失效 IP |

没写但值得知道的：`disable_cache`（排查时有用）、`cache_capacity`、`reverse_mapping`（**官方明确说在 macOS 这类系统代理并缓存 DNS 的环境下容易出问题**，别开）、`client_subnet`。

> `independent_cache` 已在 **1.14 废弃**，所以本配置没有。1.12/1.13 上写它仍有效，但升级后会报废弃告警。

### 2.3 `inbounds`

#### TUN

| 字段 | 本配置 | 说明 |
|---|---|---|
| `interface_name` | `utun233` | 固定下来便于 `ifconfig` 排查。如遇冲突可整行删掉让系统自动分配 |
| `address` | `172.19.0.1/30` | **只给 IPv4 = 不启用 IPv6**。1.10 起 `inet4_address`/`inet6_address` 合并成了这个字段 |
| `mtu` | `9000` | |
| `auto_route` | `true` | 把默认路由指向 TUN。官方提醒：为避免流量回环，必须同时设置 `route.auto_detect_interface` 或 `default_interface` 或 `bind_interface`——本配置用前者 |
| `strict_route` | `false` | 官方说明它可让不支持的网络不可达并防 Windows 多网卡 DNS 泄漏，同时可能让某些应用无法工作。**macOS 上开启常导致局域网设备不可达**，故关闭；由此带来的 DNS 问题用 2.2 的方式解决 |
| `stack` | `gvisor` | `system` 用系统栈，`gvisor` 用虚拟栈，`mixed` 是 system TCP + gvisor UDP。**默认值取决于编译标签**，显式写死更可控 |

> **1.14 新增 `dns_mode` 与 `dns_address`。** 默认 `dns_mode: hijack`，且 `dns_address` 未设置时会自动劫持派生地址上的 DNS，效果等同一条 `hijack-dns` 路由动作。所以在 1.14 上配置里那条显式 `hijack-dns` 是冗余的——保留无害，1.13 及以下必须有。

#### mixed

`127.0.0.1:10808` 同时提供 SOCKS5 和 HTTP 代理。

**别删它。** 没有 GUI 日志窗口之后，它是唯一能绕开 TUN 单独验证节点链路的手段：

```bash
curl -s --max-time 10 -x socks5h://127.0.0.1:10808 https://api.ipify.org
```

能返回 vpstrans 的 IP，说明内核、节点、REALITY 握手全部正常，问题只可能在 TUN 那一层。这一步能把故障范围直接砍一半。

**`listen` 必须写 `127.0.0.1` 而不是 `0.0.0.0`**，否则局域网内任何人都能用你的代理。

### 2.4 `outbounds`

两条 VLESS 出站，**唯一的区别是 `uuid`**：

| 字段 | 说明 |
|---|---|
| `tag` | 路由规则里 `outbound` 填的值 |
| `server` / `server_port` | 两条节点**完全相同**——都连 vpstrans |
| `uuid` | 身份凭证。服务端据此决定本地出网还是中转到住宅 IP |
| `flow` | `xtls-rprx-vision` |
| `packet_encoding` | `xudp`。多目标 UDP（游戏、部分 P2P）需要它 |
| `tls.server_name` | SNI，必须与服务端 REALITY 的目标一致 |
| `tls.utls` | uTLS 指纹伪装。**REALITY 必须开** |
| `tls.reality.public_key` / `short_id` | 服务端签发 |
| `domain_resolver` | 解析 `server` 里域名时用哪个解析器。本配置 `server` 填 IP 所以用不上，写着是为了兼容 |

direct 出站的 `domain_resolver` 含义不同——官方明确区分：**`direct` 出站影响的是"请求里的域名"，其他出站影响的是"服务器地址里的域名"**。所以这里的 `{server: dns-direct, strategy: ipv4_only}` 意思是：走直连的请求用国内 DoH 解析，且只要 IPv4。

> 官方的 `type: block` 和 `type: dns` 出站**都已废弃**，现在用路由动作代替，见 2.9。

### 2.5 `route` 顶层

| 字段 | 说明 |
|---|---|
| `auto_detect_interface` | 自动跟随系统默认网卡。与 `auto_route` 配套，是防流量回环的必需项，也是切换 Wi-Fi 后能自愈的原因。**别改成写死 `default_interface`**，那样换网络就断 |
| `default_domain_resolver` | 所有没单独指定 `domain_resolver` 的出站默认用它。1.12 引入 |
| `final` | 都没命中时走哪个出站 |

### 2.6 `route.rules[]` 与匹配语义

#### 动作分终止型与非终止型

**这是最容易写错的地方。** 并非所有动作都终止匹配：

| 动作 | 命中后 | 说明 |
|---|---|---|
| `route`（写了 `outbound` 就是它） | **终止** | 派给指定出站 |
| `reject` | **终止** | 拒绝 |
| `hijack-dns` | **终止** | 交给内置 DNS 模块 |
| `sniff` | **继续** | 只做协议嗅探，给后续规则补上域名信息 |
| `resolve` | **继续** | 只把域名解析成 IP，让后面的 IP 类规则有东西可匹配 |
| `route-options` | **继续** | 只调整本次连接的选项 |

这正是第一条 `{"action":"sniff"}` 不会把所有流量吞掉的原因——它匹配一切，但不终止。**如果 `sniff` 是终止型动作，后面十几条规则一条都不会执行。**

#### 单条规则内部：同字段"或"，跨字段"与"

```json
{ "network": "udp", "port": 443, "action": "reject" }
```
= UDP **且** 443 → 只拦 QUIC，不影响 DNS(53) 和 Discord 语音。

```json
{ "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" }
```
= 命中 geosite-cn **或** geoip-cn。

所以 `domain_suffix` 和 `rule_set` **不能塞进同一条规则**（会变成"域名后缀匹配**且**规则集匹配"，几乎永远不命中），必须拆开。配置里的 TikTok 补丁就是因此单独成条的。

需要跨字段取"或"时可用逻辑规则 `{"type":"logical","mode":"or","rules":[...]}`，本配置为可读性选择拆成多条——效果等价，且日志里能一眼看出命中的是哪条。

#### 本配置的规则逐条

| 序 | 规则 | 在做什么 |
|---|---|---|
| 1 | `{"action":"sniff"}` | 对所有流量做嗅探。**必须第一条**：TUN 收到的是 IP 包，不嗅探就没有域名，后面所有域名规则和 `rule_set` 全部失效 |
| 2 | `{"protocol":"dns","action":"hijack-dns"}` | DNS 流量交给内置模块，不让它出网 |
| 3 | `{"ip_is_private":true}` → `direct` | 私有地址直连。取代老写法 `geoip: private` |
| 4 | `domain_suffix: local/localhost/lan/home/home.arpa/arpa` → `direct` | 本地域名直连，保 Bonjour、AirDrop、内网主机名。`home` 用于路由器常见的 `*.home`，`home.arpa` 是 RFC 标准写法 |
| 5 | `rule_set: geosite-private` → `direct` | 规则集里的私有域名 |
| 6 | `{"network":"udp","port":443,"action":"reject"}` | 禁 QUIC |
| 7 | `rule_set: geosite-category-ads-all` → `reject` | 广告拦截（连接层） |
| 8 | `rule_set: [anthropic, openai, category-ai-!cn]` → `vpstrans` | AI |
| 9 | `rule_set: [github, google, bing]` → `vpstrans` | 工具 |
| 10 | `domain_suffix: [tt* 四个]` → `vpsre` | TikTok 规则集漏掉的 CDN 域补丁 |
| 11 | `rule_set: [tiktok, meta, x, telegram, discord, whatsapp]` → `vpsre` | 社交 |
| 12 | `rule_set: geoip-telegram` → `vpsre` | Telegram 会回落到内置 DC IP 直连，这类连接没有域名，靠这条兜住 |
| 13 | `rule_set: [apple-cn, microsoft-cn]` → `direct` | 中国化直连，**必须排在第 14 条之前**，否则会被 `geolocation-!cn` 捞去代理 |
| 14 | `rule_set: [gfw, geolocation-!cn]` → `vpstrans` | 墙外兜底 |
| 15 | `rule_set: [geosite-cn, geoip-cn]` → `direct` | 国内兜底 |
| — | `final: vpstrans` | 以上全不命中 |

#### 顺序原则

1. **非终止动作放最前**：`sniff`、`hijack-dns` 必须是第 1、2 条。
2. **越具体越靠前**：局域网 → 拦截 → 具体业务 → 大类地理 → `final`。
3. **拦截类放在放行类之前**：广告 `reject` 如果排在 `geolocation-!cn → 代理` 后面，绝大多数广告域名会先被后者捞走，拦截形同虚设。
4. **例外规则压在通用规则之上**：想让某个域名不落进后面的大类规则，就在它之前单独开一条。

#### 关于第 14、15 条的顺序：这是取舍不是最优解

把 `geosite-cn` / `geoip-cn` 放在 `gfw` / `geolocation-!cn` **之后**，两个方向都有代价：

* **收益**：`geosite-cn` 含一条裸的 `domain_suffix: "cn"`，匹配**所有** `.cn` 域名，其中一部分实际需要走代理。放到后面，`geolocation-!cn` 先拿到判定权。
* **代价**：同时出现在两个集合里的域名一律走代理，国内可直连的境外站点会绕路。
* **次生不一致**：`dns.rules` 里 `geosite-cn` 仍走国内解析，可能出现"用国内 DNS 拿到国内 IP、却走代理去连它"。不致命，但会莫名其妙地慢。

**这个收益比看起来小**：第 8/9 条已把 AI、GitHub、Google、Bing 提前捞走，它们的 `.cn` 域名（`googleapis.cn` 等）根本轮不到第 15 条。裸 `cn` 后缀的实际影响只剩"不属于前面任何业务组、但确实需要代理的 `.cn` 域名"。别假设 `geosite-google` 一定收录了它们，用 `sing-box rule-set match google.srs services.googleapis.cn` 验一下，不命中就按 2.7 加显式规则。

对"宁可多绕一圈也不漏出去"的取向，这个顺序自洽。**日后发现国内站点明显变慢，第一个要怀疑这里，而不是节点。**

#### 一个容易忽略的陷阱：IP 规则匹配不到域名连接

经过嗅探的连接携带的是**域名**。IP 类规则（`ip_cidr`、`geoip-*`）匹配的是目标 IP，对这类连接**不会命中**，除非插入 `{"action": "resolve"}`。

本配置没有插 `resolve`，是刻意的：

* 域名侧由 `geosite-cn` 覆盖，IP 侧的 `geoip-cn` 兜住直接用裸 IP 发起的连接（很多客户端软件、P2P、Telegram 都这么干）。两者分工，不重叠。
* 插 `resolve` 意味着每条未命中的连接都要先做一次 DNS 查询才能继续匹配，既增加延迟，也让"解析走哪个 DNS"和"路由走哪个出站"互相纠缠，出问题极难定位。

代价是：某个境外域名如果 `geosite` 没收录、但它的 IP 在 `geoip-cn` 里，不会被判直连，会走到 `final` 代理。对本方案来说这个方向的错误可以接受。

> 顺带说明：这也解释了为什么删掉 `geoip-telegram` 省不下开销——IP 规则只对裸 IP 连接生效，成本是一次 CIDR 字典树查找，纳秒级。删掉它反而会让 Telegram 的 IP 回落流量落到 `final` 走机房出口，与社交组统一走住宅 IP 的意图冲突。

### 2.7 `route.rule_set[]`

| 字段 | 本配置 | 说明 |
|---|---|---|
| `type` | `remote` | 另有 `local`（读本地文件）和 `inline`（直接写在配置里） |
| `format` | `binary` | 对应 `.srs`；`source` 对应未编译的 `.json` |
| `download_detour` | `vpstrans` | **通过代理下载**，规则集在国内多半下不动 |
| `update_interval` | `7d` | 自动更新周期 |

#### `.srs` 和 `.json` 的区别

同一份规则集，上游通常两种文件都提供，**内容等价，只是载体不同**：

| | `.json`（`format: "source"`） | `.srs`（`format: "binary"`） |
|---|---|---|
| 可读性 | 纯文本，能看、能 diff、能手改 | 二进制 |
| 体积 | 大 | 通常只有 json 的几分之一 |
| 加载 | 每次启动解析文本再建索引 | 已编译好，直接映射，启动快、内存低 |
| 用途 | 自己写、审查内容 | 日常运行、远程下载 |

`format` 必须和文件真实格式对应，写反了会加载失败——这是规则集报错里最常见的一种。

转换与排查命令：

```bash
sing-box rule-set compile category-ai-!cn.json -o category-ai-!cn.srs
sing-box rule-set decompile geosite-cn.srs          # 看规则集里到底有什么
sing-box rule-set match geosite-cn.srs claude.ai    # 测某个域名会不会命中
```

`match` 是排查分流问题最快的办法——怀疑某域名被误捞时，一条命令就能证实，不用改配置重启试。

> 这些命令需要本地有 `.srs` 文件。**`type: remote` 的规则集存在 `cache.db` 里，磁盘上没有单独文件**，得自己另下一份，见 5.2。

> **`.srs` 有格式版本**，随 sing-box 演进升级。上游用新版生成的 srs，旧内核可能读不了，报错往往只是"加载失败"看不出原因。**内核大版本升级后建议手动触发一次规则集更新。**

#### 规则集内部不是顺序匹配

这一点和外层的 `route.rules` 完全不同：

* **外层规则表**：有序，自上而下，命中即终止。
* **规则集内部**：无序，本质是一个**集合**。只回答"这个域名/IP 属不属于这个集合"。

原因是规则集里装的是 *headless rule*（无动作规则），**没有 `outbound`、没有 `action`**，不存在"先命中哪条决定走哪里"的问题。编译成 `.srs` 后更是如此：域名走前缀树、IP 走 CIDR 字典树，"顺序"在数据结构层面已经不存在。

**由此带来一个限制**：无法在规则集内部做排除。想把某个域名从 `geosite-cn` 里摘出来，只能在外层、在引用该规则集的规则**之前**加一条自己的规则压过去。想反向匹配整个集合则用规则的 `invert` 字段。

#### 多个规则集写一条还是拆成多条

**结果完全一样，性能差别可以忽略。** 两种写法最坏情况下都要做同样多次集合查找，多出来的只是几次"规则对象字段为空"的判断，相对于集合查找本身微不足道。真正影响性能的是规则集的数量和体积，不是写成几行。

选择依据是工程性的：

| | 合并 | 拆开 |
|---|---|---|
| 日志可读性 | 只知道"第 13 条命中" | 能看出**具体哪个集合**命中 |
| 中间插规则 | 不行，是一个整体 | 可以插入例外 |
| 动作不同 | 做不到 | 天然支持 |
| 后续误改风险 | 高：加个 `port` 会 AND 到全部集合 | 低 |

建议：意图和动作都相同、不打算中间插东西的就合并；**调试期临时拆开**，日志里立刻能定位是哪个集合的问题，查完再合回去。

#### 规则集来源：为什么用 MetaCubeX

SagerNet 官方的 sing-geosite 源自 v2fly 数据，**没有 `gfw` 分类**，也没有 `apple-cn` / `microsoft@cn` 这样直接可用的子集。MetaCubeX 的 sing 分支源自 Loyalsoldier 数据，这几个都有。

**但分类命名不都是望文生义的，上线前必须逐个验证 URL**：

```bash
BASE=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo
for f in geosite/private geosite/category-ads-all geosite/anthropic geosite/openai \
         "geosite/category-ai-!cn" geosite/github geosite/google geosite/bing \
         geosite/tiktok geosite/meta geosite/x geosite/telegram geosite/discord \
         geosite/whatsapp "geosite/apple@cn" "geosite/microsoft@cn" geosite/gfw \
         "geosite/geolocation-!cn" geosite/cn geoip/cn geoip/telegram; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/$f.srs")
  echo "$code  $f"
done
```

重点怀疑对象：`x.srs`（上游历史分类名是 `twitter`）、`meta.srs`（历史名是 `facebook`）、`anthropic.srs` / `bing.srs`（是否单独成类）、`apple@cn.srs`（MetaCubeX 文档里用的是 `apple-cn`，而 microsoft 确实是 `@cn` 形式，两者写法不同）。

**为什么必须验**：`type: remote` 的规则集下载失败时，sing-box **不会拒绝启动**，只在日志里留一条告警，然后这条规则永远不命中。表现是"某类流量莫名走了兜底"，而规则表看起来完全正确。这是本方案最隐蔽的一类故障。

拿不准的分类，用 `sing-box rule-set decompile` 打开看一眼实际域名，比猜名字快。

#### 冷启动的先后问题

规则集要通过代理下载，而代理选择又依赖规则集。实际不会死锁——规则集没就绪时路由退化到 `final`（全走 vpstrans），此时代理可用，规则集下得下来，下一轮就正常。**所以首次启动后等十几秒再测分流。**

#### 规则集 vs 显式域名

**默认用规则集。** 手写域名列表有三个坏处：会过时（新服务上线、老服务换域名，列表不会自己长）、会漏（一家服务往往有主站/API/CDN/鉴权好几个域名）、难维护。

**只有三种情况需要显式域名**：

1. 规则集还没收录（刚上线或小众服务）。加进去，过几个月回头检查，上游收录了就删掉。
2. 要覆盖规则集的判断。
3. 绕开规则集的已知缺陷——最实际的用途。

**补丁的写法**是在被覆盖的规则**之前**单独开一条：

```json
{ "domain_suffix": ["googleapis.cn", "gstatic.cn"], "outbound": "vpstrans" }
```

这个例子来自 `geosite/cn.srs` 的裸 `cn` 后缀缺陷（见 2.6）。**本配置多半不需要它**——`geosite-google` 排在中国直连之前，这些域名早被捞走了；先 `match` 验证，命中就别加。留着是为了说明两件事：补丁必须压在通用规则之前，以及上游规则集会有缺陷、需要你自己兜。

判断标准：**规则集是主力，显式域名是补丁。** 补丁应该短、有注释说明为什么加、定期回收。如果显式列表长到几十行还在增长，多半是数据源选错了。

配置里保留的 4 个 `tt*` 域名就是合格的补丁——MetaCubeX 的 tiktok 分类漏了这几个 CDN 域，它们以 `tt` 开头，关键字匹配也捞不到。

同一条规则里还有个 `ipinfo.io`，性质不同：它不是分流需求，而是**诊断用途**——把它固定到 `vpsre`，5.9 的"两个出口 IP 必须不同"才有确定的参照物。代价是 IP 查询会走住宅出口，流量极小可以接受。

### 2.8 `experimental.cache_file`

| 字段 | 说明 |
|---|---|
| `enabled` | 持久化 DNS 缓存和规则集，重启不用重新下载 |
| `path` | **必须用绝对路径**，理由见 3.2 |
| `store_fakeip` | 本配置不用 FakeIP，保持 `false` |

#### `experimental.clash_api`（可选，排查分流的利器）

开了之后可以用 Clash 面板看**每条活跃连接命中了哪条规则、走了哪个出站**，比翻日志直观得多。
**`config/config.example.json` 里已经带上了它**，`secret` 是必须替换的占位符之一；不想要就把整个 `clash_api` 块删掉：

```json
"experimental": {
  "cache_file": {
    "enabled": true,
    "path": "/usr/local/etc/sing-box/cache.db",
    "store_fakeip": false
  },
  "clash_api": {
    "external_controller": "127.0.0.1:9090",
    "external_ui": "ui",
    "external_ui_download_url": "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
    "external_ui_download_detour": "vpstrans",
    "secret": "换成一串随机字符"
  }
}
```

`sudo launchctl kickstart -k system/sing-box` 重启后打开 `http://127.0.0.1:9090/ui`，首次进入填 `127.0.0.1:9090` 和你设的 secret。

| 字段 | 说明 |
|---|---|
| `external_controller` | API 监听地址。**必须绑 `127.0.0.1`** |
| `external_ui` | 面板文件目录。**相对路径**，相对 plist 里的 `WorkingDirectory`（即解到 `/usr/local/etc/sing-box/ui`）。没设 `WorkingDirectory` 就得写绝对路径 |
| `external_ui_download_url` | 面板来源。换成 zashboard 等其他面板改这里即可 |
| `external_ui_download_detour` | **面板要通过代理下载**，指向 `vpstrans` |
| `secret` | 访问口令，必填 |

**两条安全要求别省**：

* `external_controller` 绑 `127.0.0.1` 而不是 `0.0.0.0`。
* `secret` 必须设。

这个接口能改配置、切换出站——暴露出去等于把代理控制权交出去。**排查完建议把整段注释掉。**

> 需要内核带 `with_clash_api` 编译标签，官方 release 是带的（用 3.1 的 `sing-box version` 确认）。

#### 不装面板的轻量替代

```bash
sudo lsof -nP -i -a -p $(pgrep -x sing-box)    # 内核当前的所有连接
sudo nettop -p $(pgrep -x sing-box)            # 实时流量
```

但这两个只能看到 IP 和端口，**看不到域名和命中的规则**——分流调试还是得靠面板或 `log.level: debug`。

### 2.9 版本兼容对照

| 废弃写法 | 废弃版本 | 现在的写法 |
|---|---|---|
| 入站的 `sniff` / `sniff_override_destination` | 1.11 | 路由规则 `{"action":"sniff"}` |
| `type: block` 出站 | 1.11 | 路由规则 `{"action":"reject"}` |
| `type: dns` 出站 | 1.11 | 路由规则 `{"action":"hijack-dns"}` |
| `geoip` / `geosite` 的 `.db` 数据库 | 1.8 | `rule_set` |
| DNS 的 `{"address":"https://..."}` 旧格式 | 1.12 | `{"type":"https","server":"..."}` |
| 出站的 `domain_strategy` | 1.12（1.14 移除） | `domain_resolver: {server, strategy}` |
| TUN 的 `inet4_address` / `inet6_address` | 1.10 | 合并为 `address` |
| TUN 的 `gso` | 1.11 | 已无效，删掉 |
| `dns.independent_cache` | 1.14 | 删掉 |
| DNS 规则动作里的 `strategy` | 1.14（1.16 移除） | 用 `domain_resolver` 或 `dns.strategy` |

**升级前的固定动作**：先读官方的 Migration 与 Deprecated 两页，再 `sing-box check -c config.json`。废弃项通常只告警不报错，很容易在一次静默降级之后才发现分流不对了。

---

## 3. 安装 sing-box

### 3.1 用官方 release，别用 Homebrew

```bash
VER=1.14.0   # 换成 release 页面上的实际版本号
cd /tmp
curl -LO "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-darwin-amd64.tar.gz"
tar xzf "sing-box-${VER}-darwin-amd64.tar.gz"

sudo install -m 755 "sing-box-${VER}-darwin-amd64/sing-box" /usr/local/bin/sing-box
sudo xattr -d com.apple.quarantine /usr/local/bin/sing-box 2>/dev/null
sing-box version
```

Intel 选 **`darwin-amd64`**（`arm64` 是 Apple Silicon）。

**两个不用 Homebrew 的理由**：

* **构建标签不保证。** 本方案用 `"stack": "gvisor"`，而 Homebrew 从源码构建时是否带 `with_gvisor` 没有保证。`sing-box version` 的输出会列出编译标签，确认有 `with_gvisor` 才能用 gvisor 栈，否则把配置改成 `"stack": "system"`。
* **Homebrew 本体可能跟不上系统。** 在较新的 macOS 上会报 `unknown or unsupported macOS version`，需要 `brew update-reset` 才能恢复。sing-box 是单文件二进制、没有依赖链，手动装反而是更稳的长期选择——升级就是重下一个文件覆盖掉。

### 3.2 放置配置

先把第 1 章的配置存成本地文件（如 `./config.json`，占位符全部替换完），再放到位：

```bash
sudo mkdir -p /usr/local/etc/sing-box
sudo cp ./config.json /usr/local/etc/sing-box/config.json
```

配置里 `experimental.cache_file.path` 用的是**绝对路径** `/usr/local/etc/sing-box/cache.db`。这不是随手写的：相对路径在前台运行时相对当前目录尚可，交给 launchd 后台运行时工作目录不确定，缓存会落到意外位置或直接失败。

---

## 4. macOS 系统层准备（不可跳过）

本节都是**要做的动作**，做完不用马上逐条验证——统一到 [5.7](#57-系统层复查) 一次跑完。之所以单独成章而不并进第 5 章，是因为这些是配置文件管不了的前置条件：不先做，后面的验证不可能通过。


### 4.1 关闭 IPv6

**为什么配置里拦了 AAAA 还不够。** TUN 只有 IPv4 地址（`172.19.0.1/30`），`auto_route` 也就只接管 IPv4 默认路由。系统的 IPv6 默认路由仍指向物理网卡——只要有一个可用的 IPv6 地址，流量就直接从 en0 裸奔出去，连路由规则都碰不到。

DNS 层拦 AAAA 是"让应用拿不到 IPv6 地址"，属于兜底；关掉系统接口才是"让机器根本没有 IPv6 可用"，是根治。**三层缺一不可**：

```bash
# 第 1 层：系统网络接口 —— 先看你机器上实际有哪些服务
networksetup -listallnetworkservices

# 验证
ifconfig en0 | grep inet6
```

服务名因机器而异，**照抄别人的命令多半会报错**——比如 `Ethernet` 是有线网卡服务，Intel MacBook Pro 没有内置网口，只有插了 USB/雷雳转以太网适配器才会出现这一条；没插就没有，对它执行 `setv6off` 会提示服务不存在。

> **哪些 inet6 是正常的，不用管：**
> * `fe80::…` —— 链路本地地址，出不了本地网段，测试站也用不到它。
> * `::1 prefixlen 128` —— 环回地址，在 `lo0` 上，等价于 IPv6 版的 `127.0.0.1`。它是系统内部通信用的，**关不掉也不该关**，很多本地服务依赖它。
>
> **要消除的只有全局地址**：`2xxx:` / `2409:` / `240e:` 这类开头、且出现在 `en0` 等物理网卡上的。只要它们没了，就算关干净了。

典型输出与处理方式：

| 服务名 | 是什么 | 要不要关 IPv6 |
|---|---|---|
| `Wi-Fi` | 无线网卡，日常上网主力 | **必须关** |
| `iPhone USB` | 用数据线连 iPhone 走个人热点（USB 网络共享） | **必须关**——它是一条真实的上网通道，走它上网时 IPv6 照样能出去 |
| `Thunderbolt Bridge` | 雷雳网桥，两台 Mac 之间直连组成的本地网络 | 视用途而定，见下 |

所以你的机器要执行的是：

```bash
sudo networksetup -setv6off "Wi-Fi"
sudo networksetup -setv6off "iPhone USB"
```

**服务名含空格必须加引号**，否则 `networksetup` 会把它当成多个参数报错。

**`Thunderbolt Bridge` 关不关？** 它不用于访问互联网，只在你用雷雳线直连另一台 Mac 时才有流量，所以**不关也不会造成泄漏**。但要注意它反过来的影响：Mac 之间的点对点发现依赖 IPv6 链路本地地址，关掉可能让雷雳网桥传文件不可用。**如果你用这个功能就别关；不用的话，关掉更省心**——将来插上雷雳设备时不会突然多出一条没设防的通道。

第 2 层是 TUN 只配 IPv4 地址，第 3 层是 DNS 拦 AAAA/HTTPS 记录，两者都已写在配置里（见 2.2、2.3）。

恢复用 `sudo networksetup -setv6automatic "Wi-Fi"`。

> **这个设置按网络服务生效，不会继承。** 以后接新网卡、或连手机热点时系统新建了网络服务，都要重新执行一次。这是"以为关了其实没关"最常见的来源——所以 5.7 的复查脚本值得在换网络、换硬件后跑一遍。

### 4.2 把系统 DNS 指向非局域网地址

这一步最容易被跳过，症状却最迷惑：**能上网，但访问 Google 之类被污染的域名时解析出一个完全无关的 IP**（比如 `157.240.x.x`，那是 Facebook 的段），连接自然失败。

**根因**：`auto_route` 把默认路由指向 utun，但局域网网段仍然直连物理网卡——`192.168.1.0/24 via en0` 比默认路由更具体。如果系统 DNS 是路由器地址（`192.168.1.1` 这类），这个查询根本不会进 TUN，也就轮不到配置里的 `hijack-dns` 规则，明文出去直接被投毒。

`strict_route` 本可以解决，但 macOS 上开启它常导致局域网设备不可达（见 7.6），所以我们用另一种方式绕开：

```bash
sudo networksetup -setdnsservers "Wi-Fi" 1.1.1.1
sudo dscacheutil -flushcache
```

填什么其实无所谓——反正会被 sing-box 劫持。填 `1.1.1.1` 只是为了保证它**不是内网地址**，这样查询才会走默认路由进 TUN。

#### 4.2.1 脚本切系统 DNS 与 1.14 的 `dns_mode`：保留，不引入 `dns_mode`

sing-box 1.14.0 给 `tun` 入站加了 `dns_mode`，文档说它能在 Apple 平台上做 per-interface DNS。
这会让人以为脚本的 `networksetup -setdnsservers`（`dns_apply_proxy`）可以退休了——**不能**，立场是保留，
依据如下：

- sing-box v1.14.0 依赖 sing-tun `v0.9.0-beta.4`（`go.mod:58`）。那个版本的 `tun_darwin.go` **没有任何设置接口 DNS
  的代码**；设置接口 DNS 的实现只有 `tun_windows.go:84-109` 的 `luid.SetDNS`，以及 Linux 的 nftables / iproute2 分支。
- 文档里「per-interface DNS on Apple platforms」指的是图形客户端走 NetworkExtension 的路径，命令行内核在 macOS 上没有这条路。
- 真机旁证：内核 1.14.0 运行中，Wi-Fi 的 DNS 仍是脚本设的 `1.1.1.1`，`scutil --dns` 里没有 utun 作用域的解析器。

所以 `dns_backup_save` / `dns_apply_proxy` 的行为一字不动。**sing-tun 在 darwin 上实现接口 DNS 设置的那天要重评**——
看点是 sing-tun 的 `tun_darwin.go` 出现 DNS 相关代码，届时 `dns_mode` 才有可能替代 `networksetup`。

### 4.3 退掉其他 VPN 客户端

macOS 上同时只能有一个 TUN 客户端正常工作。启动前完全退出 Surge / Clash / Tailscale / 公司 VPN，否则 utun 抢占会导致虚拟网卡建不起来。

**先说清楚一件事**：`ifconfig | grep utun` 一定会有输出，**这不代表有冲突**。macOS 自己就会为 iCloud 私密转发、Handoff、隔空播放等功能创建 `utun0`–`utun3` 之类的接口，它们始终存在、也不该动。真正会抢占的是第三方 VPN 客户端。

**查谁在占**：

```bash
# 1) 常见的第三方 VPN / 代理进程
ps -axo pid,comm | grep -Ei "tailscale|clash|surge|mihomo|xray|v2ray|openvpn|wireguard|warp|nord|express"

# 2) 系统级 VPN 配置（系统设置里添加的那种）
scutil --nc list

# 3) 看哪个 utun 真的承载了默认路由
netstat -rn -f inet | grep -E 'default|^0/1|^128\.0/1'
```

**怎么退**：

| 类型 | 操作 |
|---|---|
| 菜单栏 GUI 客户端 | 从菜单栏退出，或 `osascript -e 'quit app "Surge"'` |
| Tailscale | `tailscale down`，或退出 App |
| 系统设置里的 VPN | `scutil --nc stop "<配置名>"`（名字取自 `scutil --nc list`） |
| 后台守护进程 | `sudo launchctl list \| grep -i <关键字>` 找到 Label，再 `sudo launchctl bootout system/<Label>` |
| iCloud 私密转发 | 系统设置 → Apple ID → iCloud → 关闭「私密转发」 |

> **别用 `kill -9`。** 正常退出时这些客户端会自己拆掉 utun 并还原路由表；强杀会留下残留路由，症状是断网且看不出原因。理由同 6.3。
>
> 实在理不清谁在占，重启一次最省事——残留路由和孤儿 utun 都会被清掉。
>
> **iCloud 私密转发是特例**：它不抢 utun，但会接管 DNS 和部分流量，让分流结果对不上。排查阶段先关掉。

### 4.4 浏览器自带 DoH 要关掉

Chrome 默认会对部分域名自动升级到**内置 DoH**，完全绕开系统 DNS、也就绕开了 sing-box。它可能用 HTTP/3 发这个请求，正好撞上配置里的 `udp/443 → reject`，于是解析卡死——典型症状是 Google 打不开而别的站正常。

* Chrome：`chrome://settings/security` → 关闭「使用安全 DNS」
* Firefox：`about:config` → `network.trr.mode` 设为 `5`

---

## 5. 验证清单

**验证顺序的原则：先用不需要 root、不动系统路由表的手段，再上 TUN，最后才做成服务。** 前面几步出错不会把网络搞断，也不用反复重启服务；等它们都干净了，问题范围就只剩 TUN 那一层。

每小节末尾都有「不通过时」分支，**照着分支走，不要跳回去改配置**——大多数返工都是因为在错误的层面上改东西。

### 5.1 静态校验（不启动内核）

```bash
sing-box check  -c /usr/local/etc/sing-box/config.json    # 语法 + 引用完整性
sing-box format -c /usr/local/etc/sing-box/config.json    # 规范化输出，加 -w 直接写回
sing-box version                                          # 看编译标签
```

`format -w` 顺手统一缩进，配合 git 用能让 diff 干净很多。

> 子命令在不同版本略有差异，`sing-box --help` 能确认你这版有哪些。

**不通过时**

| 报错 | 原因 | 处理 |
|---|---|---|
| `JSON syntax error` 之类 | 语法错 | `python3 -m json.tool config.json` 能报出具体行号，比 `check` 的提示更准 |
| 提到某个 rule-set 找不到 | **悬空引用**——`dns.rules` 或 `route.rules` 引用了 `route.rule_set` 里没定义的 tag | 两边对齐；删规则集时记得同时删引用 |
| `deprecated` 告警 | 用了旧字段 | 对照 2.9 改掉。**告警不阻止启动**，但可能已经静默降级 |
| `version` 输出里没有 `with_gvisor` | 内核构建不带 gVisor | 把配置改成 `"stack": "system"`，或换官方 release 二进制（见 3.1） |

### 5.2 规则集验证

#### 规则集文件在哪

**`type: remote` 的规则集不会在磁盘上留下 `.srs` 文件。** 它们下载后直接存进 `cache.db`，以二进制块的形式混在缓存里，没法单独取出来喂给 `rule-set match`。

想确认内核实际下到了什么：

```bash
ls -lh /usr/local/etc/sing-box/                            # cache.db 的大小和修改时间
grep -i "rule-set\|rule_set" /var/log/sing-box.log | tail -30
```

`cache.db` 有几 MB 且时间是最近的，说明规则集确实下下来了。

#### 自己下一份来排查

要用 `match` / `decompile`，得另外下：

```bash
mkdir -p ~/singbox/rules && cd ~/singbox/rules

BASE=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo
curl -x socks5h://127.0.0.1:10808 -LO "$BASE/geosite/google.srs"
curl -x socks5h://127.0.0.1:10808 -LO "$BASE/geosite/cn.srs"

sing-box rule-set match google.srs services.googleapis.cn   # 某域名会不会命中
sing-box rule-set decompile cn.srs | less                   # 看集合里到底有什么
```

`-x socks5h://127.0.0.1:10808` 走自己的代理下——`raw.githubusercontent.com` 在国内多半直连不了。这也正是配置里给每个规则集写 `download_detour: vpstrans` 的原因。

`match` 是排查分流最快的手段：怀疑某域名被误捞时一条命令就能证实，不用改配置重启试。

#### 想锁定版本可以改成本地文件

```json
{
  "type": "local",
  "tag": "geosite-google",
  "format": "binary",
  "path": "/usr/local/etc/sing-box/rules/google.srs"
}
```

**代价是不再自动更新**，得自己写定时任务重下。`cn`、`geolocation-!cn` 这类变动挺勤，除非有特殊理由要锁版本，否则 `remote` + `update_interval` 更省事。

**不通过时**

* **下载返回 404**：分类名不对。重点怀疑 `x`（上游可能叫 `twitter`）、`meta`（可能叫 `facebook`）、`anthropic` / `bing`（可能不单独成类）、`apple@cn`（MetaCubeX 文档里是 `apple-cn`）。改名或换源，改完记得配置里的 `url` 也要同步。
* **`decompile` 报错但文件确实下下来了**：`.srs` 格式版本比你的内核新。换用与内核版本匹配的规则集源，或升级内核。
* **`match` 结果与预期不符**：这不是故障，是规则集内容与你的假设不符。按 2.7 的原则决定是加显式补丁还是换源——**别急着改路由顺序**。

### 5.3 连通性快测

```bash
sing-box tools connect your.vpstrans.host:443     # 端口通不通
sudo sing-box tools fetch -c /usr/local/etc/sing-box/config.json https://api.ipify.org
```

`tools fetch` 用配置里的出站发一次请求，能确认**节点本身可用**（REALITY 握手成功、能取回内容）。

> **它不能用来验证分流。** `tools fetch` 只是拿配置起一个临时上下文发请求，日志里不会输出路由匹配明细——即使把 `log.level` 调成 `debug` 也不会。真正能看到"某域名命中哪条规则、派给哪个出站"的，是 5.4 的 `sing-box run` 前台运行。分流验证放在那一步做。

**到这一步为止都还没启动 TUN。**

**不通过时**：连接超时或握手失败是节点问题，排查见 5.6；规则集相关报错回 5.2。

### 5.4 前台试跑

前三步都不需要 root、不动系统路由表。确认干净之后，才第一次把 TUN 拉起来——**仍然是前台运行**，不要直接做成服务：

```bash
sudo sing-box run -c /usr/local/etc/sing-box/config.json
```

`sudo` 不能省——TUN 建虚拟网卡、改路由表必须 root。缺了它报的是 `configure tun interface: operation not permitted`。

盯着看三件事：内核是否正常启动、**每个 `rule_set` 是否下载成功**（下载失败不报错、只静默失效，见 2.7）、有没有 gVisor 相关告警。

保持它在前台跑着，另开一个终端做完 5.5–5.9。**全部通过后回到这个终端 `Ctrl-C` 停掉**，再按第 6 节做成服务——前台实例不退，服务装上也起不来（端口被占）。

**这一步不能跳过直接做服务**：后台运行时启动失败你什么都看不到，而 `KeepAlive` 还会不停把它拉起来刷日志。

**启动失败时**

| 报错 | 处理 |
|---|---|
| `operation not permitted` | 没有 root，加 `sudo` |
| `address already in use` | 端口被占，见 7.2 |
| `rule-set` 下载失败 | 回 5.2 |
| 没报错但立刻退出 | 完整看输出，通常前几行就有原因；必要时把 `log.level` 调成 `debug` |

### 5.5 服务与 TUN

```bash
pgrep -fl sing-box                                       # 有输出
ifconfig | grep utun233                                  # 网卡建起来了吗
netstat -rn -f inet | grep -E 'default|^0/1|^128\.0/1'   # 路由是否指向 utun
```

**第三条命令正常时应该输出什么**

两种形式都算正常，取决于版本与 `auto_route` 的实现：

```
default            192.168.1.1        UGScg           en0
default            link#20            UCSIg        utun233
```

或者

```
0/1                link#20            UCSI         utun233
default            192.168.1.1        UGScg           en0
128.0/1            link#20            UCSI         utun233
```

`0/1` + `128.0/1` 这一对合起来覆盖整个 IPv4 空间，且比 `default` 更具体，效果等同于接管默认路由。

> **指向 `en0` 的那条 `default` 必须保留**，不是残留。sing-box 自己的出站流量要靠它才出得去，否则就成了自己套自己。判据是**有没有一条指向 `utun233` 的路由**，而不是"只剩 utun 一条"。

**不正常的样子**：只有指向 `en0` 的 `default`，`utun233` 一行都没有。

**默认路由没指向 utun 时怎么办**

这说明 TUN 没生效，先定位原因：

```bash
tail -50 /var/log/sing-box.log      # 前台运行时直接看终端输出
```

常见原因就三个：**没有 root**（前台跑忘了 `sudo`，或服务装成了 LaunchAgent 而非 LaunchDaemon）、**别的 VPN 抢了 utun**（见 4.3）、**睡眠唤醒后路由丢了**（见 6.4）。

**修好之后必须补两件事**，否则会以为还没好：

```bash
# 1) 确认 4.2 的 DNS 设置还在
networksetup -getdnsservers "Wi-Fi"
```

返回 `1.1.1.1` 就没问题；返回 `There aren't any DNS Servers set` 或某个 `192.168.x.x`，说明被冲掉了，回 4.2 重做。公司 VPN、Tailscale MagicDNS 接管过 DNS 而退出时没还原，或系统设置里切换过"位置"，都会造成这种情况。

```bash
# 2) 清 DNS 缓存
sudo dscacheutil -flushcache
dig +short www.google.com
```

> **为什么一定要清缓存**：TUN 没生效的那段时间，DNS 查询是**明文直接出网**的——没有隧道劫持它，`1.1.1.1` 就只是一个普通的对外 UDP 请求，在国内既会被污染也构成泄漏。那期间的污染结果会留在系统缓存里，不清掉的话，TUN 修好了照样解析出错误 IP，很容易误判成"没修好"。

### 5.6 先绕开 TUN 验证节点链路

```bash
curl -s --max-time 10 -x socks5h://127.0.0.1:10808 https://api.ipify.org
```

返回 vpstrans 的 IP = 内核、节点、REALITY 全部正常。

**不通过时——别去碰 TUN 和路由规则**，问题一定在更底层：

1. **节点参数**：`uuid`、`server_name`(SNI)、`public_key`、`short_id` 任一处不对，REALITY 握手都会失败。逐字符比对服务端配置。
2. **`flow` 与服务端不一致**：两边都得是 `xtls-rprx-vision`。
3. **Mux 没关**：Vision 与 Mux 冲突。
4. **服务端或网络本身有问题**：`sing-box tools connect your.vpstrans.host:443` 测端口通不通。

### 5.7 系统层复查

第 4 节那几项设置**按网络服务生效、不会继承**，所以这一步不只是首次验证——**换 Wi-Fi、插网卡、连手机热点之后都该跑一遍**。

一条脚本把所有网络服务的 IPv6 与 DNS 一次看完：

```bash
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while IFS= read -r svc; do
  printf "%-24s " "$svc"
  printf "v6=%-4s " "$(networksetup -getinfo "$svc" | awk -F': ' '/^IPv6:/{print $2}')"
  printf "dns=%s\n" "$(networksetup -getdnsservers "$svc" | tr '\n' ' ')"
done
```

**每行都要满足**：`v6=Off`，且 `dns` 不是内网地址（`192.168.x.x` / `10.x.x.x` 这类）。任一条不满足，回 4.1 / 4.2 补。

再验证实际效果：

```bash
dig +short www.google.com            # 真实 Google 地址，不是 157.240.x.x 这类污染答案
ifconfig | grep inet6                # 只应剩 fe80:: 与 ::1
```

* `https://dnsleaktest.com` → Extended Test，结果里**不应出现本地运营商**
* `https://test-ipv6.com` → 判据是**未检测到 IPv6 连接**，不是看分数高低

> 这两项过不去而前面各步都正常时，先怀疑浏览器自带 DoH（见 4.4）和 iCloud 私密转发（见 4.3）——它们都会绕过内核。

### 5.8 QUIC 与局域网

* `https://cloudflare-quic.com/` 应显示未使用 HTTP/3
* `ping 192.168.1.1`、内网 SSH、AirDrop 发现设备、局域网打印机

> **不要用 `curl --http3` 来验这一条。** macOS 自带的 curl（8.7.1，SecureTransport）
> 没有编进 HTTP/3，`curl --http3 -V` 恒为失败——那不是"QUIC 被挡住了"，是这条命令
> 压根测不了。`singbox verify` 第 4 步改用另一种测法：往 `cloudflare-quic.com:443`
> 和 `quic.rocks:4433` 发一个 version 字段填保留值的 QUIC long-header 包，按 RFC 9000 §6，
> 服务端认不出版本时**必须**回一个 Version Negotiation 包。**收到回包 = UDP/443 出得去
> = 禁 QUIC 规则没生效**；两个端点全超时才算已阻断。
>
> 已知局限：全超时时"已阻断"与"本机 UDP 整体出不去"分不开，脚本按前者这个乐观读法判。

**不通过时**

* **仍在用 HTTP/3**：先清浏览器的 socket 缓存（Chrome：`chrome://net-internals/#sockets` → Flush socket pools），再确认禁 QUIC 那条规则在广告拦截之前、且 `network` 和 `port` 两个字段都写了。
* **局域网设备不可达**：检查私有地址那几条规则是不是排在最前面（第 3–5 条）。如果你把 `strict_route` 打开了，关掉它——这是 macOS 上最常见的原因，见 7.6。
* **AirDrop / 隔空播放失效**：确认 `domain_suffix` 里有 `local`，且 `224.0.0.0/4` 一类的组播地址被 `ip_is_private` 覆盖。

### 5.9 出口 IP 与国内直连

前面几步验的是"流量派给了谁"，这一步验"**实际从哪里出网**"——两者不是一回事。

```bash
curl -s https://api.ipify.org         # 走 final 兜底 → 应是 vpstrans 机房 IP
curl -s https://ipinfo.io/json        # 已在社交组 → 应是 vpsre 住宅 IP
curl -s https://cip.cc                # 国内站直连 → 应显示本地城市与运营商
```

三条各验一件事：

| 命令 | 验什么 | 判据 |
|---|---|---|
| `api.ipify.org` | 兜底出站可用 | 返回 vpstrans 的机房 IP |
| `ipinfo.io/json` | **服务端按 UUID 分流是否生效** | 与上一条**必须是不同地址**，且 ISP 为住宅运营商而非机房 |
| `cip.cc` | 国内直连未被代理 | 显示你本地的城市与运营商，且**这个 IP 不等于第一条走 SOCKS 拿到的出口 IP** |

> 最后那半句是 `singbox verify` 第 5 步的机器判据：两者相等就说明国内流量全被代理接走了，
> 直连规则没生效。`cip.cc` 抽风时脚本会依次退到 `myip.ipip.net`、`ip.3322.net`，
> 三家全挂才报失败——"这一步没有结论"本身就是一条结论，不该被当成通过。

**第二条最关键，也最容易被跳过。** 它验的是"实际从哪里出网"，而日志只能告诉你"派给了谁"——**证明不了 vpsre 的出口真是住宅 IP**。vpsre 到住宅节点那段中转在服务端，客户端看不见；中转挂了的话日志照样打 `outbound/vless[vpsre]`，出口却已经变回机房 IP。这是客户端侧唯一能发现它的手段。

**配合日志看分流命中。** 5.4 还在前台跑着的话，那个终端里每条连接都有一行：

```
INFO [...] outbound/vless[vpsre]: outbound connection to <某个 tiktok 域名>:443
```

**方括号里的出站 tag 就是路由结果。** 正常浏览一会儿，看社交类域名是不是都落在 `vpsre`、AI 和工具类落在 `vpstrans`、国内域名不出现在任何代理出站里——比逐个 `curl` 覆盖面大得多。

想进一步看**为什么**走这条出站（命中第几条规则），把 `log.level` 调成 `debug` 或 `trace` 重跑；或用 Clash 面板的连接列表（见 2.8），它直接给出每条连接的规则与出站链。

> 配置里已把 `ipinfo.io` 显式加进社交组（第 10 条），所以这条判断成立。换用别的配置时要先确认它确实命中 `vpsre`。

再打开 bilibili / 淘宝，确认延迟在几十毫秒内。

**不通过时**

**前两条地址相同** → 服务端按 UUID 分流没生效，或 vpsre 的中转链路断了。这是服务端问题，客户端配置怎么改都没用。

**`api.ipify.org` 返回你本机的公网 IP** → 流量根本没进代理，回 5.5 查 TUN 是否接管。

**国内站点慢或绕路**，按可能性排序：

1. **`geoip-cn` / `geosite-cn` 没下来** → 回 5.2 验证 URL。这是最常见的。
2. **DNS 分流与路由分流不一致** → `dns.rules` 里判为国内解析的集合，必须和 `route.rules` 里判为 `direct` 的集合一致，见 2.2 结尾那条规律。
3. **第 14/15 条顺序的固有代价** → 同时属于 `cn` 和 `geolocation-!cn` 的域名会走代理，见 2.6。这是设计取舍，不是故障；真的影响体验就把两条对调。

> 注意排除干扰项：国内站点本身的抖动、以及 iCloud 私密转发（见 4.3）都会造成类似现象。

## 6. 运行与开机自启

**开始之前：先确认 5.4 的前台进程已经停掉。**

```bash
pgrep -fl sing-box     # 应该没有输出
```

还在跑的话回那个终端 `Ctrl-C`。前台实例不退就装服务，launchd 拉起的新实例会因为 `listen tcp 127.0.0.1:10808 bind: address already in use` 起不来，而 `KeepAlive` 会不停重试刷日志——排查起来很费劲，见 7.2。

**别用 `kill -9` 结束前台进程**，理由见 6.3。

### 6.1 LaunchDaemon

需要 root，所以必须放 `/Library/LaunchDaemons/`（系统级），不是 `~/Library/LaunchAgents/`（用户级，拿不到 root）。

```bash
sudo tee /Library/LaunchDaemons/sing-box.plist > /dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sing-box</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/sing-box</string>
    <string>run</string>
    <string>-c</string>
    <string>/usr/local/etc/sing-box/config.json</string>
  </array>
  <key>WorkingDirectory</key><string>/usr/local/etc/sing-box</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/sing-box.log</string>
  <key>StandardErrorPath</key><string>/var/log/sing-box.err</string>
</dict>
</plist>
EOF

sudo chown root:wheel /Library/LaunchDaemons/sing-box.plist
sudo chmod 644 /Library/LaunchDaemons/sing-box.plist

plutil -lint /Library/LaunchDaemons/sing-box.plist          # 先验语法，必须输出 OK
sudo launchctl bootstrap system /Library/LaunchDaemons/sing-box.plist
```

> **用 `bootstrap` 而不是老的 `load -w`。** `load` / `unload` 是遗留接口，报错信息含糊——最常见的 `Load failed: 5: Input/output error` 几乎不给任何线索。`bootstrap` 会明确指出是哪个字段、哪个路径的问题。旧系统（macOS 10.10 之前）才需要退回 `load`。

> 若 `which sing-box` 不是 `/usr/local/bin/sing-box`，把 plist 里的路径改成实际值。

**"开机自启"具体指什么**

`RunAtLoad` + LaunchDaemon 意味着：**系统启动时、用户登录之前**就由 launchd 拉起。不需要你登录，机器一开机代理就在——这也是它与用户级 LaunchAgent 的区别之一。

关键字段：

| 字段 | 作用 |
|---|---|
| `RunAtLoad` | 加载时立即启动，配合 LaunchDaemon 即开机自启 |
| `KeepAlive` | 进程**意外退出**时自动拉起 |
| `disable` / `enable` | 持久开关，跨重启生效。与 `bootout` / `bootstrap`（只影响本次开机）是两回事 |

**`KeepAlive` 与 `bootout` 不冲突**：`bootout` 是把整个 job 从 launchd 卸掉，没有 job 也就没有 KeepAlive，所以停下来之后不会自己起来。

### 6.2 日常操作

| 目的 | 命令 |
|---|---|
| 改完配置重启 | `sudo launchctl kickstart -k system/sing-box` |
| 停止（卸载 job） | `sudo launchctl bootout system/sing-box` |
| 启动（加载 job） | `sudo launchctl bootstrap system /Library/LaunchDaemons/sing-box.plist` |
| **彻底停用（重启后也不启）** | `sudo launchctl disable system/sing-box` |
| 解除停用 | `sudo launchctl enable system/sing-box` |
| 看 job 状态 | `sudo launchctl print system/sing-box` |
| 看日志 | `tail -f /var/log/sing-box.log` |
| 确认在跑 | `pgrep -fl sing-box` |
| 确认 TUN 生效 | `netstat -rn -f inet \| grep -E 'default\|^0/1\|^128\.0/1'` |

### 6.3 三个必须知道的坑

**① 调配置期间先 `bootout`。** `KeepAlive` 会在进程退出后自动拉起，配置写错时它会疯狂重启刷日志，且掩盖真正的报错。改配置时先停服务，前台手动跑。

> **`bootout` 只对本次开机有效。** plist 还在 `/Library/LaunchDaemons/`，重启电脑后照样自启——调配置调到一半重启了机器，会发现它又跑起来，且很可能因为端口占用干扰你的前台调试。跨越重启的调试期间加一条 `sudo launchctl disable system/sing-box`，调完用 `enable` 恢复。

**② 绝对不要 `kill -9`。** 正常退出时 sing-box 会拆掉 utun 并还原路由表；强杀会留下残留路由，症状是断网且看不出原因，只能手工清理或重启系统。用 `launchctl bootout` 或前台的 `Ctrl-C`。

**③ 睡眠唤醒可能丢路由。** 表现是能连但全部超时。

### 6.4 关于路由丢失

**没有能 100% 根除的方案。** 根因在 macOS：唤醒或切换网络时系统会重建网络配置、重置默认路由，而 utun 是用户态程序创建的，系统不负责替它恢复。所有基于 utun 的客户端都有这个问题，只是概率不同。

按性价比排序的缓解手段：

**① 先确认真是路由丢失，而不是 DNS 缓存失效**

```bash
netstat -rn -f inet | grep -E 'default|^0/1|^128\.0/1'
```
正常应看到指向 utun 的路由。如果这些还在、只是打不开网页，那是 DNS 问题，`sudo dscacheutil -flushcache` 即可。

**② 确保 `auto_detect_interface` 开着**，它能覆盖大部分切换 Wi-Fi / 插拔网线的场景，但覆盖不了深度睡眠唤醒。别手工指定固定出站网卡，那等于关掉自愈能力。

**③ 换协议栈做 A/B。** `gvisor` 与 `system` 在唤醒后的表现因机器而异，两边各跑几天挑复发率低的。**这是实测里最有效的一步。**

**④ 减少睡眠深度。** Intel Mac 进入 standby 后网络栈重建最彻底，丢路由概率最高：

```bash
sudo pmset -c standby 0
sudo pmset -c powernap 0
```
恢复默认：`sudo pmset -c standby 1 powernap 1`。代价是插电待机耗电略增。

**⑤ 自动化兜底：唤醒后自动重启服务**

```bash
brew install sleepwatcher
cat > ~/.wakeup <<'EOF'
#!/bin/bash
sleep 8
/bin/launchctl kickstart -k system/sing-box
EOF
chmod +x ~/.wakeup
```

> sleepwatcher 本身要以 root 运行才能 kickstart 系统级服务。

**不要用 `route add` 手工补路由**——sing-box 下发的是一组带 scope 的路由项，手补的那条与内核状态不一致，会出现"路由表看着对、流量却仍然漏出去"的情况，比直接超时更危险。

---

## 7. 故障排查

### 7.1 速查表

| 现象 | 最可能的原因 | 处理 |
|---|---|---|
| `configure tun interface: operation not permitted` | 没有 root | 用 `sudo` 跑；服务必须是 LaunchDaemon 不是 LaunchAgent |
| `listen tcp 127.0.0.1:10808 bind: address already in use` | 旧实例或别的程序占着端口 | 见 7.2 |
| 服务反复重启刷日志 | 配置有误 + `KeepAlive` 自动拉起 | 先 `unload`，按 5.4 前台手动跑看真实报错 |
| 看不到 utun | 其他 VPN 占用 / 权限 | 退出 Tailscale、Surge、Clash；删掉 `interface_name` 让系统自动分配 |
| 能连但全部超时 | 规则集下载失败，或路由丢失 | 查日志 rule-set 记录；按 5.5 看路由 |
| **访问 Google 解析出 `157.240.x.x`** | 系统 DNS 是内网地址，查询没进 TUN 被投毒 | 见 4.2 |
| 只有 Google 打不开，别的境外站正常 | 浏览器内置 DoH 绕过系统 DNS | 见 4.4 |
| 日志里出现 `198.18.x.x` | 跑的不是这份配置（FakeIP 来自别处） | 见 7.3 |
| IPv6 仍被检测到 | 第 1 层没做，或新网络服务未继承设置 | 见 4.1 |
| 域名规则不生效、只有 IP 规则有效 | 缺 `{"action":"sniff"}` | 检查它是不是第一条 |
| 某类流量莫名走了兜底 | 该规则集下载失败，静默不命中 | 按 2.7 验证 URL |
| 国内网站很慢 | 第 14/15 条顺序的代价，或 DNS 分流不一致 | 见 2.6 |
| 睡眠唤醒后断网 | 路由丢失 | `sudo launchctl kickstart -k system/sing-box` |

### 7.2 端口被占用

```bash
sudo lsof -nP -iTCP:10808 -sTCP:LISTEN
```

* **是自己的旧实例或别的代理客户端**：用它自己的方式退出（GUI 客户端从菜单栏退，或 `osascript -e 'quit app "名称"'`），再 `pgrep -fl "sing-box|xray"` 确认没有残留。有残留用 `sudo kill <PID>`，**不要 `-9`**。
* **是自己的旧实例**：`KeepAlive` 会拉起新实例而旧的还占着端口，于是无限重启。先 `sudo launchctl bootout system/sing-box`，确认 `pgrep` 无输出，再 `bootstrap` 重新加载。
* **是别的程序**：改自己的端口更省事，改完记得所有验证命令里的 10808 也要跟着换。

### 7.3 日志里出现 FakeIP 地址

`198.18.0.0/15` 是 FakeIP 段——不存在于真实互联网的假地址。把它送进代理隧道，对端无从解析，连接必然失败。

**本配置没有启用 FakeIP**（`dns.servers` 里没有 `type: "fakeip"`，`store_fakeip` 也是 `false`）。出现它只有两种可能：实际生效的是别的配置，或者有别的客户端在跑。

```bash
ps -ax | grep "sing-box" | grep -o "\-c [^ ]*"     # 看 -c 指向哪个文件
grep -n "fakeip\|198.18" /usr/local/etc/sing-box/config.json   # 应该搜不到
```

另外，即便开了 FakeIP，正常配置也不该把假地址送进出站——嗅探会在连接建立前把域名还原回来。假地址泄漏到 outbound 说明**嗅探链路是断的**，检查 `{"action":"sniff"}` 是不是第一条规则。

### 7.4 排查顺序建议

1. `sing-box check` — 配置本身有没有语法或引用错误（不启动，最快）
2. `pgrep -fl sing-box` — 进程在不在
3. `curl -x socks5h://127.0.0.1:10808` — 节点链路通不通（绕开 TUN）
4. `netstat -rn -f inet | grep -E 'default'` — TUN 接管了没有（预期输出见 5.5）
5. `dig +short` — DNS 解析对不对
6. `sing-box run` 前台运行 + `log.level: debug` — 某条连接具体命中哪条规则、走哪个出站

**前四步能把绝大多数问题定位到具体层面**，跳过它们直接改配置往往越改越乱。

### 7.5 服务加载失败

`sudo launchctl bootstrap system ...` 或旧语法 `load -w` 报错时，按顺序查：

```bash
# 1) plist 语法（最常中）
plutil -lint /Library/LaunchDaemons/sing-box.plist        # 必须输出 OK

# 2) 属主与权限
ls -l /Library/LaunchDaemons/sing-box.plist               # 应为 root wheel、-rw-r--r--

# 3) job 是不是已经加载了
sudo launchctl print system/sing-box                      # 有输出说明已在，重复加载会失败

# 4) 可执行文件是否存在
ls -l /usr/local/bin/sing-box
```

**语法坏掉最常见的原因**：用 `sudo tee <<'EOF'` 创建 plist 时，如果整块命令是从 Markdown 代码围栏里复制的，内层的 `EOF` 可能连带终结外层，文件被截断。`plutil -lint` 不是 `OK` 就直接重写。

修正后重新加载：

```bash
sudo chown root:wheel /Library/LaunchDaemons/sing-box.plist
sudo chmod 644 /Library/LaunchDaemons/sing-box.plist
sudo launchctl bootout system/sing-box 2>/dev/null        # 若已加载，先卸
sudo launchctl bootstrap system /Library/LaunchDaemons/sing-box.plist
```

还看不出原因就查 launchd 自己的日志：

```bash
log show --predicate 'process == "launchd"' --last 5m | grep -i sing-box
```

> `Load failed: 5: Input/output error` 是旧接口 `load` 的典型含糊报错，它几乎不给线索。**换成 `bootstrap` 重试一次**，同样的问题它会指出具体字段或路径。

### 7.6 关于 `strict_route`

官方说明它可以让不支持的网络不可达、并防止 Windows 多网卡 DNS 泄漏，代价是可能让某些应用无法工作。**macOS 上开启常导致局域网设备（AirDrop、打印机、内网 SSH）不可达**，所以本方案关闭它，转而用 2.2 的方式解决 DNS 不进 TUN 的问题。

如果你的场景不需要局域网互访，可以试着打开它，那样 2.2 就不是必须的了。

---

## 8. 安全与维护

* 只从 `github.com/SagerNet/sing-box/releases` 下载，校验 sha256。
* REALITY 的 `public_key` / `short_id` 泄漏等于节点泄漏，别把完整参数贴到任何在线工具或聊天群。
* 两条节点的 UUID 分别对应"机房出口"和"住宅出口"，住宅 IP 更宝贵，不要用于大流量下载或扫描类流量，容易被 ISP 判定异常。
* 把 `/usr/local/etc/sing-box/` 做成 git 仓库。配置改动能回溯，升级内核时对照 4.9 的废弃表也方便。
* 内核升级后：`sing-box check` → 手动触发一次规则集更新（srs 有格式版本）→ 重跑第 5 节验证清单。
* LaunchDaemon 以 root 常驻是本方案的安全代价。确保 `/usr/local/bin/sing-box` 和配置文件的属主是 root、其他用户不可写。
