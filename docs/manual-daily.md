---
kind: manual
---
# 日常运行

看状态、启停、开机自启、停服时的系统 DNS、日志。

## 前提

- 已按 [首次安装](manual-install.md) 装好，`singbox` 命令可用

## 步骤

1. 看状态

   ```bash
   singbox status     # 不带命令也是它
   ```

   三段：服务（进程、LaunchDaemon、自启）、TUN 与路由、监听端口。指向 `en0` 的那条
   `default` 是正常的，内核自己的出站要靠它；判据是「有没有一条指向 utun」。

2. 启停与重启

   ```bash
   singbox stop       # 本次开机内停止，重启电脑后照样自启
   singbox start
   singbox restart    # 改完配置用这个
   ```

3. 跨重启地停用 / 启用

   ```bash
   singbox disable    # 立即停止，并且重启后也不起
   singbox enable
   ```

   调试期间用 `disable`，否则重启后服务自己回来，还会占着端口。它管不了 `debug`
   或手动前台跑的实例，那些要回终端 `Ctrl-C`。

4. 停服时处理系统 DNS

   ```bash
   singbox stop --dns-dhcp        # 交回路由器下发，不问
   singbox stop --restore-dns     # 按安装时的备份回滚，不问
   singbox stop --keep-dns        # 保留 1.1.1.1，不问
   singbox stop --dns 223.5.5.5   # 指定地址
   singbox disable --dns-dhcp     # disable / uninstall 同样支持
   ```

   代理运行时系统 DNS 是 `1.1.1.1`；代理一停，这个地址的明文查询在国内会被污染，
   所以 `stop` / `disable` / `uninstall` 都会问是否还原。不带参数就是问一句，默认按备份回滚。

5. 单独查看或切换 DNS

   ```bash
   singbox dns status          # 当前 DNS、是否与服务状态匹配、备份内容
   singbox dns dhcp            # 交回 DHCP
   singbox dns backup          # 按备份还原
   singbox dns proxy           # 设回 1.1.1.1
   singbox dns set 223.5.5.5
   ```

   `dns status` 会交叉核对：服务在跑但 DNS 不是代理模式 → 查询可能不进 TUN；
   服务没跑但 DNS 是 `1.1.1.1` → 明文查询会被污染。`start` 时发现前者也会提醒并询问。

6. 看日志、回收空间

   ```bash
   singbox logs           # 先报体积，再打后 50 行
   singbox logs 200
   singbox logs -f        # 跟随
   singbox logs size      # 只看体积
   singbox logs truncate  # 原地清空，服务不受影响、不用重启
   ```

   launchd 不做日志轮转，`/var/log/sing-box.log` 与 `.err` 只涨不落。超过 64 MB
   （`SB_LOG_WARN_MB` 可改）时 `status` 与 `doctor` 会点名。

## 出错了看哪

- **停服后某些网站解析出错误 IP** → `singbox dns dhcp`。
- **`start` 后能上网但分流不对** → `singbox dns status`，DNS 不是代理模式就 `dns proxy`。
- **`status` 显示监听 `*:10808`** → 配置里 `listen` 写成了 `0.0.0.0`，局域网内谁都能用你的代理，改回 `127.0.0.1`。
- **日志几百 MB** → `singbox logs truncate`。不要 `mv` / `rm` 日志文件：守护进程会继续往旧 inode 写，空间收不回来，新日志也看不到。
- **`disable` 后端口仍被占** → 是前台 `debug` 或手动跑的实例，回那个终端 `Ctrl-C`。
- **备份里的 DNS 是 `1.1.1.1`** → 会被当成 DHCP 处理（装脚本前手动设过的情况）。拿不准直接 `--dns-dhcp`。
- 更多症状：`singbox doctor`，见 [检查与排查](manual-check.md)。

## 深入阅读

- [运行与开机自启：三个必须知道的坑](best-practices.md#63-三个必须知道的坑)
- [日志为什么只能原地截断](best-practices.md#93-日志为什么只能原地截断)
- [DNS 备份为什么把 1.1.1.1 当 DHCP](best-practices.md#94-dns-备份的归一化)
