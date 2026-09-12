---
kind: manual
---
# 检查与排查

装完、换了网络、感觉分流不对、想知道哪坏了——按这个顺序跑。

## 前提

- 服务在跑（`singbox status`）。`verify` / `syscheck` / `rules` 不需要 sudo

## 步骤

1. 完整验证

   ```bash
   singbox verify
   ```

   六步：① SOCKS 出口（绕开 TUN）② 两个出口 IP 必须不同 ③ DNS 是否被投毒
   ④ IPv6 / QUIC ⑤ 国内直连与局域网 ⑥ 配置里有没有废弃字段。没有任何一步会静默跳过。

   | 退出码 | 含义 |
   |---|---|
   | `0` | 全过 |
   | `1` | 链路档失败：SOCKS 不通、取不到出口 IP、两个出口相同、有全局 IPv6。换内核可能修好 |
   | `2` | 策略档失败：DNS 污染或无解析手段、QUIC 没被阻断、国内出口等于代理出口、网关不通、参照站取不到、配置有废弃字段。回滚内核换不回来 |

2. 换过网络就复查系统层

   ```bash
   singbox syscheck     # 退 0 全合格；1 有服务 IPv6 未关或 DNS 是内网地址
   singbox sysprep      # 不合格时修复
   ```

   IPv6 与 DNS 设置按网络服务生效、不会继承：插网线转接器、iPhone USB 热点、
   公司 VPN 退出没还原 DNS、切换「位置」，都会留下缺口，而代理看起来一切正常。

3. 验证规则集

   ```bash
   singbox rules        # 退 0 全可达；1 有不可达
   ```

   规则集下载失败时内核照样启动，只是那条规则永远不命中。内核大版本升级后也跑一次。

4. 看每条连接走了哪个出站

   ```bash
   singbox debug        # 停掉服务、前台 debug 跑；Ctrl-C 后自动恢复服务
   ```

   正常浏览，看日志里 `outbound/vless[vpsre]` 方括号里的 tag——那就是路由结果。

5. 一键诊断

   ```bash
   singbox doctor       # 退 0 未发现已知问题；1 命中了判据
   ```

   自动判读十类问题：权限、端口占用、规则集下载失败、FakeIP 泄漏、DNS 投毒、废弃字段、
   路由未接管或只接管了一半、plist 语法、IPv6 未关、服务未运行。全套信息写到
   `/tmp/singbox-keep-*/doctor-*.txt`（0600，含访问过的域名与日志，贴出去前先看一眼）。

## 出错了看哪

- **`verify` 第 1 步失败** → 节点参数错，与 TUN、路由无关。见 [首次安装](manual-install.md) 的出错项。
- **第 2 步两个 IP 相同** → 服务端 UUID 分流没生效或住宅中转断了。日志里照样打 `[vpsre]`，这是客户端唯一能发现它的手段。不确定就 `debug` + 另开终端 `curl -s https://ipinfo.io/json`。
- **退出 2 但上网正常** → 你正在失去的是分流本身。按打 `✗` 的那步查：`rules` 看规则集下来没、`debug` 看连接落在哪。
- **报「本机没有可用解析手段」** → 不是污染，是 `dig` / `host` / `dscacheutil` / `python3` 都没拿到 A 记录。先确认能上网，再看 `syscheck` 的系统 DNS。
- **`rules` 报 404** → 分类名不对：`x` 上游可能叫 `twitter`、`meta` 叫 `facebook`、`apple@cn` 有的源写 `apple-cn`。
- **`doctor` 报「TUN 只接管了一半默认路由」** → 比「未接管」更隐蔽：另一半地址正从 en0 直连。`restart` 后再看。
- **`syscheck` 报 `fe80::` / `::1`** → 不会。那是链路本地与环回，脚本只报全局地址。
- **`syscheck` 注了一行 `fdxx::` ULA** → 也不算。多半是 Xcode 设备隧道（插着 iPhone 时 `utunN` 上的 `fdf8:…::2`）或 Docker 的虚拟网卡，公网不可路由；脚本点名它只是让你知道它被看见了。

## 深入阅读

- [验证清单：每步的「不通过时」分支](best-practices.md#5-验证清单)
- [故障排查速查表](best-practices.md#71-速查表)
- [verify 为什么分两档退出码、第 2 步为什么最关键](best-practices.md#92-verify-的两档退出码)
- [verify 收紧（设计记录）](verify-hardening.md)
