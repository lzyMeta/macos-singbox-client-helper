---
kind: design
covers:
  - singbox.sh
  - config/config.example.json
---
# config audit 结论解读

> `singbox config audit` 报告里每条「怎么办」背后的问题、拿仓库模板举的例子、怎么判断要不要改、改成什么样。
> 报告详情区的「解读」链接锚到本文的对应小节（`#<条目 id>`）。
> 官方迁移页（[migration](https://sing-box.sagernet.org/migration/)、[deprecated](https://sing-box.sagernet.org/deprecated/)）
> 的完整语义以链接为准，本文只写「对本仓库模板这份配置意味着什么」。
> 「模板未命中」的条目，例子取自 sing-box v1.14.0 tag 下 `docs/` 的官方片段（GPL-3.0-or-later，引用附链接）。

---

## 怎么读这份文档

**报告三档各意味着什么。** `起不来`：内核拒绝这份配置，现在就跑不起来，退出码 1；`将来会坏`：字段已废弃、
内核仍接受，下个大版本会拒收，退出码 2；`提示`：配置合法，只是**行为变了**，要人确认是不是想要的，不影响退出码。

**「谁发现的」四种来源。** `check`：内核 `sing-box check` 打出的 WARN / FATAL；`schema`：内核 JSON schema 不认识的键；
`表`：脚本自带的迁移表（`singbox.sh` 里的 `TABLE`）按 JSON 路径与具名谓词逐条对配置求值；`run`：`--deep` 在沙箱里
真跑一次内核，收割 `Start()` 阶段才打的 WARN。同一处被多路发现时合并成一行，来源并列。

**`--deep` 与离线的差别。** 离线审只看配置文本，看不到远程规则集的内容；`--deep` 起沙箱把规则集下下来、走完
`Start()`。所以有两条只有 `--deep` 能定性：规则集里到底有没有 IP 条目，以及只在 `Start()` 阶段告警的废弃用法。

**「`--deep` 后消失」= 已定性为不需要改。** 离线报的 `提示` 若在 `--deep` 后不见了，报告会在表格下面打一行
`--deep 已排除 N 条：<位置> <原因>`——不是漏报，是沙箱证明了它不成立。

**本文覆盖哪些条目。** 迁移表里 `fix` 不是 `auto` 的全部条目（`--apply` 能自动改的 3 条不在这里：
`download_detour` / `independent_cache` / `store_rdrc`，跑 `config audit --apply` 就行）。每节标题是条目 `id`，
固定四段：**问题是什么 → 模板里的例子 → 怎么判断 → 改成什么样**。「模板」指 `config/config.example.json`，
它与真机 live 配置逐键全等（`tests/template.test.sh` 在守），所以拿模板举例就是拿你的配置举例。

---

## 只报不改的 19 条

### query_type_ip_version_semantics

**报告原话：确认内部解析也受它影响是想要的**

**问题是什么**：1.14.0 之前，`dns.rules` 里的 `query_type` / `ip_version` 只对**应用发来的** DNS 查询生效
（TUN 截获的、DNS 入站收到的）。1.14.0 起它们对**每一次** DNS 规则求值都生效，包括 sing-box **自己发起**、
又没有指定 DNS 服务器的解析——官方页称之为「内部解析」：路由动作 `resolve` 不带 `server` 时的查询、
`direct` 出站为 ICMP 目标做的解析、WireGuard / Tailscale endpoint 解析自己的服务器地址、SOCKS4 出站的本地解析、
DERP 的 bootstrap DNS。不移除，只是范围变大。另外这类规则不能与遗留地址过滤 / `strategy` 动作 /
`rule_set_ip_cidr_accept_empty` 共存于同一份 DNS 配置（内核会拒绝）。
官方页：[ip_version and query_type behavior changes in DNS rules](https://sing-box.sagernet.org/migration/#ip_version-and-query_type-behavior-changes-in-dns-rules)。

**模板里的例子**：`dns.rules[0]`——所有 AAAA / HTTPS 查询直接回空答案，是「DNS 层拦 IPv6」的实现：

```json
{
  "query_type": ["AAAA", "HTTPS"],
  "action": "predefined",
  "rcode": "NOERROR"
}
```

1.14.0 起，凡是走 DNS 规则的内部解析，AAAA 也一律拿到空答案——内核自己**永远拿不到任何 IPv6 地址**。

**怎么判断**：看两处。

1. 内部解析**过不过 DNS 规则**。官方页明说：指定了服务器的解析——出站拨号字段 `domain_resolver`、
   `route.default_domain_resolver`、DNS 动作或 `resolve` 动作里显式的 `server`——**不经过 DNS 规则匹配，不受影响**。
   模板三个出站都配了 `"domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"}`，`route.default_domain_resolver`
   也指到 `dns-direct`，`resolve` 动作一条都没有。所以模板里这条规则实际影响不到任何内部解析。
2. 就算过了 DNS 规则，**想不想要 IPv6**。看 `dns.strategy` 与各 `domain_resolver.strategy`：模板全是 `ipv4_only`，
   内核本来就只用 IPv4，AAAA 回空对它零影响。

两条都成立，**这条提示对模板 / 真机配置是「想要的」，不用改**。什么时候要改：`strategy` 是 `prefer_ipv6` / `ipv6_only`；
或某个出站服务器只有 AAAA 记录（纯 IPv6 VPS）且它没配 `domain_resolver`；或新加了不带 `server` 的 `resolve`
动作、后面的路由规则又依赖 IPv6 `ip_cidr`。

**改成什么样**：把「限定到应用查询」的想法先放下——DNS 规则的 `inbound` 字段**排除不了**内部解析，因为由连接触发的
内部解析（`resolve` 动作、direct 出站）继承了那条连接的入站上下文（`route/conn.go` 的 `adapter.WithContext`）。
两种可行改法：

- 删掉 `dns.rules[0]`，靠 `strategy` 控制：`"dns": {"strategy": "ipv4_only"}` 本身就让 AAAA 回空 NOERROR、
  HTTPS 应答剥掉 `ipv6hint`（`dns/client.go`），效果与这条规则等价，且只影响你指定它的那一层。
- 要保留这条规则又要内核自己能用 IPv6：给每个出站配 `domain_resolver: {"server": ..., "strategy": "prefer_ipv6"}`，
  让它们的解析绕开 DNS 规则。

### legacy_address_filter_rs

**报告原话：规则集是 geoip/IP 类才算；纯域名（geosite-*）可忽略，拿不准用 --deep 定性**

**问题是什么**：1.14.0 把 DNS 规则里按**响应 IP** 过滤的写法（`ip_cidr` / `ip_is_private` / `ip_accept_any` 不带
`match_response`）废弃，1.16.0 移除；改成先 `"action": "evaluate"` 取到响应，再在下一条用 `match_response`
显式匹配。DNS 规则引用规则集时，如果规则集**只含 `ip_cidr` 条目**（典型是 `geoip-*`）又没开 `match_response`，
内核就把它当成这种废弃用法（`dns/router.go` 靠规则集元数据判）。离线审只看得到规则集**名字**，看不到内容，
所以只能报 `提示`。官方页：[Migrate address filter fields to response matching](https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching)。

**模板里的例子**：`dns.rules[1]` 引用 `geosite-category-ads-all`，`dns.rules[2]` 引用 `geosite-cn` / `geosite-apple-cn` /
`geosite-microsoft-cn`：

```json
{
  "rule_set": "geosite-category-ads-all",
  "action": "predefined",
  "rcode": "NXDOMAIN"
},
{
  "rule_set": ["geosite-cn", "geosite-apple-cn", "geosite-microsoft-cn"],
  "server": "dns-direct"
}
```

四个都是 `geosite-*`，纯域名规则集，不含任何 IP 条目。

**怎么判断**：先看名字——`geosite-*` 是域名集，`geoip-*` 是 IP 集；前者可忽略，后者就是废弃用法。
名字看不出来的（自建规则集）跑 `singbox config audit --deep`：沙箱真跑一次内核，规则集含 IP 条目内核会打
`Legacy Address Filter Fields` 这条 WARN，本条升为「将来会坏」；不含，本条撤掉并在表格下打一行
`--deep 已排除 1 条：… 引用的规则集经沙箱确认不含 IP 条目`。**`--deep` 后这条消失 = 已定性为不是废弃用法，不用改。**
模板 / 真机就是这种情况。

**改成什么样**：确实是 `geoip-*` 时，把 IP 规则集从原来那条 DNS 规则里拆出去，改成官方页的两条形式——先
`evaluate` 用某个服务器查到响应，再 `match_response` 按响应 IP 命中规则集决定用哪个服务器：

```json
{
  "dns": {
    "rules": [
      {
        "action": "evaluate",
        "server": "remote"
      },
      {
        "match_response": true,
        "rule_set": "geoip-cn",
        "action": "route",
        "server": "local"
      },
      {
        "action": "route",
        "server": "remote"
      }
    ]
  }
}
```

（官方示例；`server` 名按你自己的 `dns.servers` 替换。规则里若同时带了 `query_type`，两条都要带。）

### implicit_http_client

**报告原话：给这条规则集写内联 http_client**

**问题是什么**：远程规则集下载走哪个出站，1.14.0 之前可以什么都不写——既没有 `http_client` 也没有
`download_detour`、顶层 `http_clients` 与 `route.default_http_client` 也都空时，内核隐式用**默认出站**下载。
1.14.0 起这个隐式默认是废弃行为，1.16.0 移除；内核 `Start()` 阶段打 `implicit default HTTP client` WARN，
离线审靠 `表` 的谓词抓，`--deep` 也抓得到。官方页：[rule-set › http_client](https://sing-box.sagernet.org/configuration/rule-set/#http_client)。

**模板里的例子**：模板未命中——模板每条远程规则集都写了 `"http_client": {"detour": "vpstrans"}`。
官方页无改前/改后 JSON，原话是：*When neither `http_clients` nor `default_http_client` is configured, an implicit HTTP
client connecting through the default outbound is used. This implicit default is deprecated in sing-box 1.14.0.*

**怎么判断**：报告「在哪」列出的每条 `route.rule_set[N]`，看它是否 `type: remote` 且没有 `http_client`：
`python3 -c 'import json,sys; [print(r["tag"]) for r in json.load(open(sys.argv[1]))["route"]["rule_set"] if r.get("type")=="remote" and "http_client" not in r and "download_detour" not in r]' config.json`。
列出来的就是要改的；一条都没有而报告仍报，看顶层 `http_clients` 是否存在但为空。

**改成什么样**：给每条远程规则集写内联 `http_client`，`detour` 指到你希望用来下载的出站（通常是代理出站）：

```json
{
  "type": "remote",
  "tag": "geosite-cn",
  "format": "binary",
  "url": "https://…/geosite-cn.srs",
  "http_client": {"detour": "vpstrans"}
}
```

不建议改用 `route.default_http_client`：它是全局副作用，会改掉所有没写 `http_client` 的规则集的下载路径。
有 `download_detour` 的规则集属 `download_detour` 条目，`config audit --apply` 会自动改。

### inline_acme

**报告原话：改用 certificate_providers**

**问题是什么**：入站 TLS 里内联的 `tls.acme` 1.14.0 废弃，1.16.0 移除；证书签发改由 `certificate_providers`
统一管理，TLS 只引用一个 provider。内核 `New()` 阶段打 `inline ACME` WARN，`check` 能抓。
官方页：[Migrate inline ACME to certificate provider](https://sing-box.sagernet.org/migration/#migrate-inline-acme-to-certificate-provider)。

**模板里的例子**：模板未命中——模板只有 `tun` 与 `mixed` 两个入站，没有 TLS。以下是官方页的例子。改前：

```json
{"tls": {"enabled": true, "acme": {"domain": ["example.com"], "email": "admin@example.com"}}}
```

**怎么判断**：报告「在哪」给出 `inbounds[N].tls.acme` 就是它，没有别的判断——这个键存在即废弃。
只跑 sing-box 客户端、没有对外服务的入站，不会碰到这条。

**改成什么样**：把 `acme` 块整体搬到 `certificate_providers[]`，TLS 里用 `certificate_provider` 引用：

```json
{"tls": {"enabled": true, "certificate_provider": {"type": "acme", "domain": ["example.com"], "email": "admin@example.com"}}}
```

（官方示例的最小形式，`domain` / `email` 等原字段照搬。）

### dns_rule_strategy

**报告原话：ipv4_only / ipv6_only 按详情里的片段改；prefer_* 直接删**

**问题是什么**：DNS 规则动作里的 `strategy`（1.12.0 加入）1.14.0 废弃、1.16.0 移除，官方没给替代写法
（内核 WARN 里的迁移链接是死链）。它做的事按内核源码是：`ipv4_only` = AAAA 查询直接回空 `NOERROR`、HTTPS 应答剥掉
`ipv6hint`；`ipv6_only` 对称；`prefer_*` 只影响内部 Lookup 的排序，对客户端查询没有效果。内核 `Start()` 阶段
打 WARN，离线靠 `表` 抓。官方页：[DNS rule action › strategy](https://sing-box.sagernet.org/configuration/dns/rule_action/#strategy)。

**模板里的例子**：模板未命中——模板的 IPv6 控制走 `dns.strategy: "ipv4_only"` 与各出站的
`domain_resolver.strategy`，DNS 规则里没有 `strategy`。官方页无改前/改后 JSON。

**怎么判断**：看报告「在哪」那条规则的 `strategy` 值：`prefer_ipv4` / `prefer_ipv6` 直接删，行为不变；
`ipv4_only` / `ipv6_only` 按下面改。

**改成什么样**：这条是 `fix: snippet`，报告详情区已经按你的规则生成了「建议写法」——在原规则**之前**插入一条
`predefined` 规则（条件照抄原规则，`query_type` 限定 AAAA 或 A，`action: predefined`、`rcode: NOERROR`），
再删掉原规则的 `strategy`。片段按 v1.14.0 源码语义推导、未经行为验证，且 HTTPS 应答里 `ipv6hint` /
`ipv4hint` 的剥离没有等价写法——只拦 AAAA 与官方 `ipv4_only` 差这一点，照抄前核对一下。

### accept_empty

**报告原话：删掉，改用 evaluate + match_response**

**问题是什么**：`rule_set_ip_cidr_accept_empty` 是遗留地址过滤的配套项（规则集按响应 IP 匹配时，空响应算不算命中），
1.14.0 与地址过滤一起废弃、1.16.0 移除。内核 `New()` 阶段打 WARN，`check` 能抓。
官方页：[Migrate address filter fields to response matching](https://sing-box.sagernet.org/migration/#migrate-address-filter-fields-to-response-matching)。

**模板里的例子**：模板未命中。官方页的例子（改前）：

```json
{"dns": {"rules": [
  {"rule_set": "geoip-cn", "action": "route", "server": "local"},
  {"action": "route", "server": "remote"}
]}}
```

**怎么判断**：键存在即废弃，没有别的判断。它一定伴随一条按 IP 规则集过滤的 DNS 规则，改那条规则时一并删。

**改成什么样**：删掉这个键，所在规则按 [legacy_address_filter](#legacy_address_filter) 改成 `evaluate` +
`match_response` 两条；新写法里空响应不再需要单独处理。

### legacy_address_filter

**报告原话：改为 evaluate + match_response（见详情建议写法）**

**问题是什么**：DNS 规则直接带 `ip_cidr` / `ip_is_private` / `ip_accept_any` 却没开 `match_response`——键都合法，
用法废弃（1.14.0），1.16.0 起拒绝。旧语义是「用本条 `server` 查，响应 IP 不匹配就继续下一条」，而且**对非地址查询整条跳过**；
新写法要显式两步：`"action": "evaluate"` 取响应，再 `match_response` 匹配。内核 `Start()` 阶段打
`Legacy Address Filter Fields` WARN。官方页同 [accept_empty](#accept_empty)。

**模板里的例子**：模板未命中——模板的 DNS 规则不按响应 IP 过滤。官方页的改前 / 改后见 [legacy_address_filter_rs](#legacy_address_filter_rs)
的「改成什么样」。

**怎么判断**：报告「在哪」列出的规则里有上面三个键之一、且没有 `match_response: true`，就是它；
有 `match_response` 的已经是新写法，不会被报。

**改成什么样**：这条是 `fix: snippet`，报告详情区已经按你的规则生成了两条替换写法：第一条 `evaluate`
用**原规则的 `server`**（不是官方示例里换成 remote——那会换掉决定服务器，不等价），第二条 `match_response` 引用第一条的
`tag`、带上原来的 IP 条件、`action: respond`；两条都限定 `query_type: ["A","AAAA","HTTPS"]`，对应旧语义「非地址查询整条跳过」。
片段按 v1.14.0 源码语义推导、未经行为验证，照抄前核对。

### hysteria_v1_tuning

**报告原话：删掉，改用共享的 quic 参数**

**问题是什么**：1.14.0 把 HTTP/2 与 QUIC 参数统一成所有 QUIC 出入站（Hysteria / Hysteria2 / TUIC）与 HTTP 客户端共享，
Hysteria v1 自己那套调优字段 `recv_window_conn` / `recv_window` / `recv_window_client` / `max_conn_client` /
`disable_mtu_discovery` 随之废弃，1.16.0 移除。**内核不会告警**（字段标了 `schema:"omit"` 但没有对应的 deprecated Note），
deprecated 页也没列——只有 `表` 能抓。官方页：[changelog 1.14.0](https://sing-box.sagernet.org/changelog/#1140)（脚注）。

**模板里的例子**：模板未命中——模板出站是 vless，没有 Hysteria。官方页无 JSON，原话：*This deprecates the Hysteria v1
tuning fields `recv_window_conn`, `recv_window`, `recv_window_client`, `max_conn_client` and `disable_mtu_discovery`; they
will be removed in sing-box 1.16.0.*

**怎么判断**：`type: hysteria`（v1，不是 `hysteria2`）的出站或入站里有这五个键之一即命中。这些值多半是照抄服务端
或客户端示例来的，删掉后用默认值通常没有可感知差异。

**改成什么样**：删掉这五个键。确实需要调窗口大小的，改用共享的 `quic` 参数块（官方页未给最小示例，字段名以
[QUIC 共享参数](https://sing-box.sagernet.org/configuration/shared/quic/) 页为准）。

### tun_removed_fields

**报告原话：删掉即可**

**问题是什么**：`tun` 入站的 `endpoint_independent_nat` 与 `gso` 在源码里标 `Deprecated: removed`，1.11.0 废弃、1.13.0 起
内核**静默忽略**——不告警、不报错，只是不生效。文档有出入：官方 tun 页仍把 `endpoint_independent_nat` 列为有效字段、
未标废弃；`gso` 有小节说明 1.11.0 起不再生效。以迁移表（对着源码核过）为准：留着没坏处，也没作用。
官方页：[TUN inbound](https://sing-box.sagernet.org/configuration/inbound/tun/)。

**模板里的例子**：模板未命中——模板的 `tun-in` 没有这两个键。官方页无改前/改后 JSON；改前形如 `"gso": false`。

**怎么判断**：键存在即命中。想确认它确实没作用：`--deep` 沙箱日志里不会出现任何与它相关的行。

**改成什么样**：删掉这两个键，其余不动。

### dns_rule_outbound

**报告原话：改用出站的 domain_resolver**

**问题是什么**：DNS 规则的 `outbound` 项（「给某个出站解析服务器域名时用这条」）1.12.0 废弃、1.14.0 移除；
解析出站服务器域名改由出站自己的拨号字段 `domain_resolver` 指定。内核 `Start()` 阶段打 `` `outbound` DNS rule `` WARN。
官方页：[Migrate outbound DNS rule items to domain resolver](https://sing-box.sagernet.org/migration/#migrate-outbound-dns-rule-items-to-domain-resolver)。

**模板里的例子**：模板未命中——模板三个出站都带 `domain_resolver`。官方页的例子，改前：

```json
{"dns": {"servers": [{"address": "local", "tag": "local"}], "rules": [{"outbound": "any", "server": "local"}]},
 "outbounds": [{"type": "socks", "server": "example.org", "server_port": 2080}]}
```

**怎么判断**：报告「在哪」那条 DNS 规则带 `outbound` 键就是它。看它的 `server` 是哪个 DNS 服务器——那就是要搬到出站
`domain_resolver.server` 里的值。

**改成什么样**：删掉这条 DNS 规则，给每个 `server` 是域名的出站写 `domain_resolver`（或统一设
`route.default_domain_resolver`）：

```json
{"outbounds": [{"type": "socks", "server": "example.org", "server_port": 2080, "domain_resolver": {"server": "local"}}]}
```

### outbound_domain_strategy

**报告原话：改为 domain_resolver: {server, strategy}**

**问题是什么**：出站 / endpoint 拨号字段 `domain_strategy` 1.12.0 废弃、1.14.0 移除，并入 `domain_resolver.strategy`。
内核 `Start()` 阶段打 WARN。官方页：[Migrate outbound domain strategy option to domain resolver](https://sing-box.sagernet.org/migration/#migrate-outbound-domain-strategy-option-to-domain-resolver)。

**模板里的例子**：模板未命中——模板出站写的已经是 `"domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"}`。
官方页的例子，改前：

```json
{"type": "socks", "server": "example.org", "server_port": 2080, "domain_strategy": "prefer_ipv4"}
```

**怎么判断**：报告「在哪」给出 `outbounds[N].domain_strategy` / `endpoints[N].domain_strategy` 就是它。
同时看该出站有没有 `domain_resolver`：没有，就要一起补 `server`（见 [missing_domain_resolver](#missing_domain_resolver)）。

**改成什么样**：

```json
{"type": "socks", "server": "example.org", "server_port": 2080,
 "domain_resolver": {"server": "local", "strategy": "prefer_ipv4"}}
```

`strategy` 的值原样搬过去，`server` 填一个 `dns.servers` 里的 tag。

### missing_domain_resolver

**报告原话：给出站加 domain_resolver，或设 route.default_domain_resolver**

**问题是什么**：出站的 `server` 是域名，却既没有 `domain_resolver`、`route` 也没有 `default_domain_resolver`——
1.12.0 起靠隐式默认解析是废弃行为，1.14.0 内核 `Start()` 阶段打 `missing domain resolver` WARN。官方没有单独的小节，
语义在 `domain_resolver` 那章：[Migrate outbound domain strategy option to domain resolver](https://sing-box.sagernet.org/migration/#migrate-outbound-domain-strategy-option-to-domain-resolver)。

**模板里的例子**：模板未命中——模板既给每个出站写了 `domain_resolver`，又设了
`"default_domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"}`。模板这样写是有意的：出站服务器域名
走直连 DNS 解析，避免「解析代理服务器的地址要先过代理」的死循环。

**怎么判断**：报告「在哪」列出的出站，`server` 是域名（不是 IP）且没有 `domain_resolver`，再看 `route` 有没有
`default_domain_resolver`。两个都没有就是它。

**改成什么样**：二选一。逐个出站加：

```json
{"type": "vless", "server": "your.server.example", "server_port": 443,
 "domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"}}
```

或在 `route` 里统一兜底：`"default_domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"}`。模板两个都写了。

### legacy_dns_servers

**报告原话：改为 type + server 的新格式**

**问题是什么**：旧式 DNS 服务器用一个带前缀的 `address` 字符串（`tls://`、`https://…/dns-query`、`local`、`dhcp://auto`…）
表达类型与地址，1.12.0 废弃、1.14.0 **移除**——现在的内核直接拒绝，报告会同时给「起不来」。新格式是 `type` + `server`
分开写。官方页：[Migrate to new DNS server formats](https://sing-box.sagernet.org/migration/#migrate-to-new-dns-server-formats)。

**模板里的例子**：模板未命中——模板已是新格式：`{"type": "https", "tag": "dns-remote", "detour": "vpstrans", "server": "1.1.1.1"}`。
官方页以 HTTPS 为例，改前：

```json
{"servers": [{"address": "https://1.1.1.1/dns-query"}]}
```

**怎么判断**：`dns.servers[]` 里有 `address` 键就是它。按前缀对到新 `type`：`local` → `local`；`tcp://` → `tcp`；
纯 IP → `udp`；`tls://` → `tls`；`https://…/dns-query` → `https`；`quic://` → `quic`；`h3://…/dns-query` → `h3`；
`dhcp://auto` / `dhcp://en0` → `dhcp`（网卡名进 `interface`）；`fakeip` → `type: "fakeip"`；`rcode://refused` 之类
不再是服务器，改成 DNS 规则动作 `predefined` + `rcode`。服务器地址是域名的还要配 `domain_resolver`；
原来写在服务器上的 `strategy` / `client_subnet` 移到规则层。

**改成什么样**：

```json
{"servers": [{"type": "https", "server": "1.1.1.1"}]}
```

其余类型照上面的映射逐个改；每种都有官方改前/改后对照，锚点在同一章。

### legacy_special_outbounds

**报告原话：改用规则动作 reject / hijack-dns**

**问题是什么**：`type: block` 与 `type: dns` 两种特殊出站 1.11.0 废弃、1.13.0 移除，功能改由路由规则动作承担：
`block` → `action: reject`，`dns` → `action: hijack-dns`。官方页说已移除，实测内核 1.14.0 对 `block` 仍接受
（迁移表 `note` 记了这个出入），但下个版本没有保证。官方页：[Migrate legacy special outbounds to rule actions](https://sing-box.sagernet.org/migration/#migrate-legacy-special-outbounds-to-rule-actions)。

**模板里的例子**：模板未命中——模板的拦截与 DNS 劫持都已是规则动作（`"action": "reject"`、`"action": "hijack-dns"`）。
官方页的例子（block），改前：

```json
{"outbounds": [{"type": "block", "tag": "block"}], "route": {"rules": [{"outbound": "block"}]}}
```

**怎么判断**：`outbounds[]` 里有 `type: block` 或 `type: dns` 即命中；再找路由规则里 `"outbound": "<它的 tag>"` 的引用，
那些规则要改动作。

**改成什么样**：删掉特殊出站，引用它的规则把 `outbound` 换成动作：

```json
{"route": {"rules": [{"action": "reject"}]}}
```

`dns` 出站对应 `{"action": "hijack-dns"}`，条件照抄原规则（通常是 `"protocol": "dns"`）。

### legacy_inbound_fields

**报告原话：改用路由规则动作 sniff / resolve**

**问题是什么**：入站上的 `sniff` / `sniff_override_destination` / `sniff_timeout` / `domain_strategy` /
`udp_disable_domain_unmapping` 1.11.0 废弃、1.13.0 移除，嗅探与域名解析改成路由规则动作 `sniff` / `resolve`，
按规则条件决定对哪些连接做。官方页：[Migrate legacy inbound fields to rule actions](https://sing-box.sagernet.org/migration/#migrate-legacy-inbound-fields-to-rule-actions)。

**模板里的例子**：模板未命中——模板的嗅探写在路由规则里（`{"action": "sniff"}`，不限入站），
且刻意不插 `resolve`（原因见 best-practices「IP 规则匹配不到域名连接」）。官方页的例子，改前：

```json
{"inbounds": [{"type": "mixed", "sniff": true, "sniff_timeout": "1s", "domain_strategy": "prefer_ipv4"}]}
```

**怎么判断**：报告「在哪」给出 `inbounds[N].<字段>` 即命中。记下每个入站的 tag——新写法要用 `inbound` 条件把动作限定回
原来的入站。

**改成什么样**：删掉入站上的这些键，在 `route.rules` 最前面加对应动作（`sniff_timeout` → `timeout`，
`domain_strategy` → `resolve` 的 `strategy`）：

```json
{"route": {"rules": [
  {"inbound": "in", "action": "resolve", "strategy": "prefer_ipv4"},
  {"inbound": "in", "action": "sniff", "timeout": "1s"}
]}}
```

`sniff_override_destination: true` 对应 `sniff` 动作后再加一条 `{"action": "route-options", "override_address": …}`
的场景很少见，通常直接去掉。

### destination_override

**报告原话：改用 route 动作的 override_address / override_port**

**问题是什么**：`direct` 出站的 `override_address` / `override_port` 1.11.0 废弃、1.13.0 移除，改为路由规则动作
`route-options`（或 `route`）里的同名选项——覆盖目标从「出站的属性」变成「规则的属性」。
官方页：[Migrate destination override fields to route options](https://sing-box.sagernet.org/migration/#migrate-destination-override-fields-to-route-options)。

**模板里的例子**：模板未命中——模板的 `direct` 出站只有 `domain_resolver`。官方页的例子，改前：

```json
{"outbounds": [{"type": "direct", "override_address": "1.1.1.1", "override_port": 443}]}
```

**怎么判断**：`type: direct` 的出站有这两个键之一即命中。找路由规则里指到这个出站的那条——覆盖要搬到它身上。

**改成什么样**：

```json
{"route": {"rules": [{"action": "route-options", "override_address": "1.1.1.1", "override_port": 443}]}}
```

条件照抄原来指向该出站的规则；出站上的两个键删掉。

### wireguard_outbound

**报告原话：改为 endpoints[] 的 wireguard 端点**

**问题是什么**：`type: wireguard` 出站 1.11.0 废弃、1.13.0 移除，WireGuard 改为顶层 `endpoints[]` 里的端点——
既能当出站用，也能收入站流量。字段结构变了：`server` / `server_port` / `peer_public_key` 合并进 `peers[]`。
官方页：[Migrate WireGuard outbound to endpoint](https://sing-box.sagernet.org/migration/#migrate-wireguard-outbound-to-endpoint)。

**模板里的例子**：模板未命中——模板没有 WireGuard。官方页的例子，改前：

```json
{"outbounds": [{"type": "wireguard", "tag": "wg-out", "server": "127.0.0.1", "server_port": 10001,
  "private_key": "<private_key>", "peer_public_key": "<peer_public_key>"}]}
```

**怎么判断**：`outbounds[]` 里 `type: wireguard` 即命中。记下引用它的路由规则与 `final`——tag 可以沿用，
引用处不用改。

**改成什么样**：

```json
{"endpoints": [{"type": "wireguard", "tag": "wg-ep", "private_key": "<private_key>",
  "peers": [{"address": "127.0.0.1", "port": 10001, "public_key": "<peer_public_key>"}]}]}
```

`local_address` → `address`，`pre_shared_key` / `allowed_ips` / `reserved` 进对应 peer；完整字段对照见官方页。

### tun_address_fields

**报告原话：改为 address / route_address / route_exclude_address**

**问题是什么**：`tun` 入站的 `inet4_address` / `inet6_address` 1.10.0 合并为 `address`，`inet4_route_address` /
`inet6_route_address` 合并为 `route_address`，`inet4_route_exclude_address` / `inet6_route_exclude_address` 合并为
`route_exclude_address`；1.12.0 移除旧名。官方页：[TUN address fields are merged](https://sing-box.sagernet.org/migration/#tun-address-fields-are-merged)。

**模板里的例子**：模板未命中——模板已是 `"address": ["172.19.0.1/30"]`。官方页的例子，改前：

```json
{"type": "tun", "inet4_address": "172.19.0.1/30", "inet6_address": "fdfe:dcba:9876::1/126"}
```

**怎么判断**：键存在即命中。这是 1.10.0 就改掉的字段，还带着它多半是从很老的示例抄来的配置。

**改成什么样**：

```json
{"type": "tun", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]}
```

`route_address` / `route_exclude_address` 同样把 v4 / v6 两个列表并成一个。

### ipcidr_match_source

**报告原话：改名为 rule_set_ip_cidr_match_source**

**问题是什么**：路由与 DNS 规则里的 `rule_set_ipcidr_match_source` 1.10.0 改名为 `rule_set_ip_cidr_match_source`，
1.11.0 移除旧名。纯改名，语义不变。官方页：[Match source rule items are renamed](https://sing-box.sagernet.org/deprecated/#match-source-rule-items-are-renamed)。

**模板里的例子**：模板未命中——模板没有按源 IP 匹配规则集的规则。官方页无独立示例，旧名出现在 GeoIP 迁移示例里：
`"rule_set_ipcidr_match_source": true`。

**怎么判断**：键存在即命中。

**改成什么样**：`"rule_set_ipcidr_match_source": true` → `"rule_set_ip_cidr_match_source": true`，值不动。
