---
kind: manual
---
# 升级、回退与卸载

升级脚本与内核、退回上一版、GitHub 下不动时换镜像、卸载。

## 前提

- 已安装；`update` / `rollback` / `uninstall` 要 sudo
- 能访问 GitHub，或至少有一个能用的镜像

## 步骤

1. 升级

   ```bash
   singbox update          # 跨 minor 时停下来问一次
   singbox -y update       # 非交互；跨 minor 那道确认默认 n，会跳过而不是闷头升
   ```

   顺序：先升脚本自己（远端 release 严格更高才换，取不到只 warn）→ 预检 → 用临时前缀
   和一份去掉 `tun`、换了端口的派生配置把新内核实跑一遍并实测建链 → 换掉
   `/usr/local/bin/sing-box` 并重启 → 跑 `verify` 验收。任一阶段失败自动回滚；
   `verify` 只在退 `1`（链路档）时回滚，退 `2` 打条 warn 放行。旧内核保留为 `sing-box.prev`。

2. 退回上一版

   ```bash
   singbox rollback        # 内核与 singbox 命令一起退，然后重新验收
   ```

   只保留一份 `.prev`，只能退一步；要更老的版本用 `singbox install --version <v>`。

3. GitHub 下不动时看镜像

   ```bash
   singbox mirror test              # 探测直连与各镜像此刻是否可用
   singbox mirror show              # 候选顺序与已记住的镜像
   singbox mirror set https://xxx   # 固定一个首选镜像
   singbox mirror reset
   ```

   `install` / `update` 会自动探测并切换（每个源最多等 6 秒，下载 20 秒内低于 2 KB/s 就换下一个），
   成功的镜像会被记住，但直连始终排最前。内置列表全挂就用自己的：

   ```bash
   export SB_MIRRORS="https://your-mirror.example https://another.example"
   ```

4. 实在都不通：手动下载内核

   ```bash
   sudo install -m 755 ./sing-box /usr/local/bin/sing-box     # 别的机器下好拷过来
   sudo xattr -d com.apple.quarantine /usr/local/bin/sing-box
   singbox install --config ./config.json                      # 检测到已安装会跳过下载
   ```

5. 卸载

   ```bash
   singbox uninstall
   ```

   移除服务、停用自启，逐项询问：删内核、删配置目录、DNS 按备份回滚、IPv6 恢复自动。
   还会在 `~/bin`、家目录等处查找前台运行留下的 `ui/` 与 `cache.db` 并询问删除。
   你自己的源配置文件（`config.json`）不会被动。

## 出错了看哪

- **「GitHub 与所有镜像均不可达」** → `singbox mirror test` 看是哪层的问题；代理能跑就先 `start`，直连往往就通了。
- **升级后某个网站进不去** → `singbox rollback`。半小时后才发现也来得及，`.prev` 留到下一次 `update` 才被覆盖。
- **升级后 `verify` 退 2** → 路由策略问题，回滚修不了。按 [检查与排查](manual-check.md) 处理。
- **升级后规则集报错** → `.srs` 有格式版本，跑 `singbox rules`；必要时换与内核匹配的规则集源。
- **旧版脚本没有自更新** → `v1.2.0` 之前装的脚本不带阶段 S，按 [首次安装](manual-install.md) 第 1 步取一次最新 release 手工重装，之后就闭环了。
- **升级中冒出莫名其妙的语法错误** → 不该发生：脚本替换用的是 `mv` 而非 `cp`。若发生，重跑 `update`。
- **`update` 后再跑 `install`** → 不会删掉 `.prev`，两者的回滚点是分开的。
- **卸载后仍有残留路由** → 脚本一律 SIGTERM 等 8 秒，不 `kill -9`。若你手动强杀过，重启电脑。

## 深入阅读

- [升级为什么要先在沙箱里实跑、校验做到哪一步](best-practices.md#96-update-的沙箱与完整性校验)
- [内核安全升级（设计记录）](safe-update.md)
- [脚本自更新（设计记录）](self-install-and-self-update.md)
- [安全与维护](best-practices.md#8-安全与维护)
