# Agent2API · Magisk 模块（arm64）

把 Agent2API 服务端（`v3.4.0`，musl 静态 arm64 构建）跑在**已 root 的 Android 手机**上：
开机自启、崩溃自愈、DNS 自适应、在线升级、一键回滚，卸载干净。

> 上游 Release 只提供 `agent2api-server-linux-arm64.tar.gz`（Rust + **glibc** 动态链接，不是 Android 的 bionic）。
> 所以这个模块的第一要务是**在 Android 上给它造一个 glibc 运行环境**——这一套至今保留，
> 服务"在线更新到上游 glibc 包"的路径。
> 随包 seed 载荷则改用 [84593320z/agent2api-musl](https://github.com/84593320z/agent2api-musl) CI 按上游 tag
> 构建的 **musl 静态**包（无 `PT_INTERP`，不依赖 glibc），模块按 `payload_dir_is_static` 自动分流两种载荷。
> 下面每一条"坑"都因 glibc 前提而来，静态载荷同样受益（DNS 改写、时区、守护全都一样走）。

---

## 1. 一分钟安装

1. 确认手机是 **arm64**（2016 年后的机器基本都是）且已 root（Magisk / KernelSU / APatch 都行）。
2. 把 `agent2api-magisk-v3.4.0-magisk.34.zip` 传到手机。
3. **Magisk**：Magisk App → 模块 → 从本地安装 → 选 zip → 重启。
   **KernelSU / APatch**：管理器 → 模块 → 安装 → 选 zip → 重启。
4. 重启后打开浏览器：`http://127.0.0.1:3065/m.html`
   第一个注册的账号就是管理员。
5. 想局域网访问：先在本机完成管理员注册，再执行 `a2a config host 0.0.0.0 && a2a restart`，然后打开 `http://<手机IP>:3065/m.html`。

装完想确认一切正常：

```sh
su -c 'sh /data/adb/agent2api/bin/a2a doctor'
```

---

## 2. 它到底做了什么（架构）

```
┌──────────────────────────── /data/adb/modules/agent2api（模块目录）────────────────────────────┐
│ module.prop  customize.sh  post-fs-data.sh  service.sh  uninstall.sh  action.sh                │
│ libexec/{common,payload,control,dns,launch,supervise,updater}.sh  libexec/a2a（CLI 真身）      │
│ 不写 /system；glibc/curl 在打包时等长改写路径，运行时只读 /data/a2a/{resolv,nsswitch,gai}     │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
                                    │ 启动时 exec
┌──────────────────────────── /data/adb/agent2api（数据目录，模块升级不会被动）──────────────────┐
│ payload/  agent2api-server(15MB)  ui/(9MB)  lib/(2.8MB 自带 glibc)  VERSION                    │
│ etc/settings.conf（你的配置，升级保留）      data/（agent2api.db 就在这）                       │
│ logs/{server.log,supervisor.log,boot.log,install.log}   run/（pid、锁、状态）                    │
│ bin/{curl,cacert.pem,a2a}   backup/prev（回滚用）   download/（升级下载）   home/  tmp/          │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

启动链路：

```
init → Magisk post-fs-data.sh（只做准备，毫秒级返回）
     → Magisk service.sh（late_start，立刻 fork 后台并 exit 0，不拖慢开机）
        → 等 boot_completed → 等网络 → 写 resolv.conf → setsid supervise.sh
           → supervise.sh 循环拉起 launch.sh（每 30s 巡检、崩溃退避、熔断）
              → exec 自带 ld.so 拉起 agent2api-server
```

为什么不给 ELF 打 `PT_INTERP` 补丁，也不用 chroot：Android 根分区只读、没有 `/lib`，
改解释器路径要求"新路径长度 ≤ 原路径"，每次应用内自更新都得重打一遍；
chroot 要往模块目录里 bind-mount `/dev`、`/proc`，卸载/异常退出容易留脏挂载。
**自带 loader 直接拉起**是最少动系统、最少留状态的做法。

---

## 3. 手机环境风险清单（这就是你要的"尽量全"）

| # | 手机上的坑 | 现象 | 本模块的对策 | 自己怎么验证 |
|---|---|---|---|---|
| 1 | Android 没有 `/lib/ld-linux-aarch64.so.1`，也没有 glibc | `exec format error` / `No such file or directory` | payload 自带 `ld.so + libc + libm + libgcc_s + libdl + libpthread + librt + libresolv + libnss_dns + libnss_files`，用 `ld.so --library-path` 拉起 | `a2a doctor` 会实测 `ld.so --version` |
| 2 | 根分区只读 | 装不上、写不进 | 所有可写内容都在 `/data/adb/agent2api`，模块目录只放脚本 | `a2a status` |
| 3 | `/etc/resolv.conf` 不存在或空 → glibc 默认只查 `127.0.0.1` | 域名全解析失败，面板转圈，签到全红 | 打包时把 glibc 的 `/etc/resolv.conf` 等长改成 `/data/a2a/resolv`；运行期按手机 DNS 自动重写，原子落盘并回读比对，不使用 mount | `a2a dns show` |
| 4 | glibc 的 NSS 要 `nsswitch.conf`，Android 没有 | `getaddrinfo` 返回 EAI_SYSTEM / 找不到主机 | glibc 改为读取 `/data/a2a/nsswitch`；Android 的 bionic 完全不接触 | `a2a doctor` 里有一项专门查它 |
| 5 | 移动网络/双栈 Wi-Fi 下 IPv6 只通一半 | 连 GitHub、连上游 API 卡 30 秒后超时（浏览器却正常） | `gai.conf` 写 `precedence ::ffff:0:0/96 100`，强制先 IPv4 | `a2a doctor`（DNS 探测项） |
| 6 | 时区/DST 不对 | 日志、签到和定时任务跨天或跨夏令时切换错误 | 读取 `persist.sys.timezone`，使用随包 IANA TZif（含历史和 DST）；缺失/损坏时拒绝启动而非静默错时区 | `a2a doctor` 的时区项 |
| 7 | 开机脚本跑太久 → 拖慢开机 / 启动超时 | 手机卡开机动画 | `post-fs-data.sh` 只做权限与清理；`service.sh` fork 后**立刻退出**；真正启动在后台等 `sys.boot_completed` | `cat /data/adb/agent2api/logs/boot.log` |
| 8 | 后台进程被 lmkd / OEM 冻结器杀掉 | 用一会儿就断，面板 502 | 守护进程 watchdog（默认 30s 巡检 + 指数退避 + 连续崩 6 次熔断）、可选 `oom_protect=1` 写 `oom_score_adj=-900`、可选 `keep_awake=1` 持有 wake_lock | `a2a status` 里的 restarts |
| 9 | 省电模式 / 深度睡眠断网 | 息屏一段时间后请求超时 | root 进程不受 Doze 的网络限制（没有 app 包名），但 CPU 会被挂起 → 需要常驻就开 `keep_awake=1`（费电，自己权衡） | 息屏 10 分钟后再访问面板 |
| 10 | 端口 3065 被别的服务占了（比如你在 Termux 跑过同一个程序） | 起不来，日志 `Address already in use` | 启动前用 `/proc/net/tcp` 查；被占时扫 `/proc/*/fd` 找出占用者 PID 并写进日志，等 60s 再试，不盲目重试 | `a2a doctor` 会显示占用者 |
| 11 | 切 Wi-Fi / 切流量后 DNS 变了 | 一开始能用，换网就解析失败 | 守护进程每 ~2 分钟比对 DNS，变了才重写（避免无谓写盘） | `a2a dns probe` |
| 12 | `/data` 空间不够 | 升级/安装到一半失败，二进制半截 | 安装前校验 `payload_validate` 七项；升级走"先写 `payload.new` → 二次校验 → 三段式 rename"；空间不足直接报错不动现有版本 | `a2a doctor`（查 /data 剩余） |
| 13 | Magisk 升级模块会**整目录替换**模块目录 | 自己塞进模块目录的东西全没了 | 载荷、配置、数据库全部在 `/data/adb/agent2api`，模块目录只放脚本 | 重装模块后数据还在 |
| 14 | SELinux | 某些 ROM 上执行 `/data` 里的 ELF 被拦 | 执行体在 `/data/adb`（magisk 域可执行），不使用 noexec 挂载点（如部分 ROM 的 `/data/local/tmp`）；权限统一 755 | `dmesg \| grep avc` |
| 15 | 应用内自更新会去覆盖自己的 `current_exe` —— 而它是 `ld.so` | 点了"更新"把运行时弄坏，服务起不来 | **`AGENT2API_SELF_UPDATE=0` 硬关**；在线升级改由 `a2a update`（sha256 校验 + 健康检查 + 自动回滚）承担 | `a2a update` |
| 16 | 升级后新版本跑不起来 | 想回退但没备份 | 升级前自动 `payload_backup`；`svc_wait_health 45` 失败自动 `payload_rollback`；手动也能 `a2a rollback` | `a2a rollback` |
| 17 | 手机是 32 位 / x86 | 装了也用不了 | `customize.sh` 里架构不符直接 `abort`，不会装一半 | — |
| 18 | 日志长期增长把 `/data` 塞满 | 越用越卡，最后写不进去 | 实际增长的是 `server.log`（上游 stderr + 启动器输出）和 `supervisor.log`，单个上限 `log_max_kb`（默认 8MB），保留 3 份轮转，守护进程每 30s 按大小 copytruncate；`boot.log` 上限 256KB。上游只在 Windows 服务形态才开 `app.log` 文件通道，Android 上不存在这个文件 | `ls -lh /data/adb/agent2api/logs` |
| 19 | 首注册被同网段设备抢走 | 未注册时首个 setup 请求成为管理员 | 新装默认 `host=127.0.0.1`；先本机注册再开放 LAN；`/v1` 未配 Key 时 fail-closed | `a2a config host` |
| 20 | 卸载后残留进程/挂载 | 端口一直被占，重启才恢复 | `uninstall.sh`：停守护 → 按 cmdline 精确清残留（**不用 `pkill -f`**，避免误杀同名字符串）→ 清理 `/data/a2a` 私有运行时链接与配置 → 默认保留数据、`purge_on_uninstall=1` 才删 | 卸载后 `ps -A \| grep agent2api` |
| 21 | 多用户 / 双开 | — | 模块是全局的，数据在 `/data/adb`，不受多用户影响 | — |
| 22 | 内核太老（getrandom 需要 ≥3.17） | 启动时报 syscall 错误 | `customize.sh` 安装期就实测 `ld.so --version`，跑不起来当场提示，不留到开机 | 安装日志 |
| 23 | 电池被这个服务耗干 | 一晚上掉一半电 | 默认 `keep_awake=0`；`battery_floor`（低于 N% 且未充电自动停服）、`wifi_only`（只在 Wi-Fi 下跑）都能开 | 设置文件 |
| 24 | 系统时间没同步（开机早期） | 证书校验失败（`certificate is not yet valid`） | 升级只在网络与时间都就绪后手动触发；curl 用 `--proto '=https' --tlsv1.2` + 自带 CA，不依赖系统 CA 库 | `a2a dns probe` |

---

## 4. 命令速查

```sh
su -c 'sh /data/adb/agent2api/bin/a2a status         ' # 状态：守护/服务端 pid、运行时长、端口、版本
su -c 'sh /data/adb/agent2api/bin/a2a doctor         ' # 全项体检（出问题第一个跑这个）
su -c 'sh /data/adb/agent2api/bin/a2a start          ' # 启动（等价于开 watchdog）
su -c 'sh /data/adb/agent2api/bin/a2a stop           ' # 停止（会写 stop 标记，守护进程退出）
su -c 'sh /data/adb/agent2api/bin/a2a restart        ' # 重启服务端
su -c 'sh /data/adb/agent2api/bin/a2a logs 200       ' # 最近 200 行（server + 守护两段）
su -c 'sh /data/adb/agent2api/bin/a2a logs sup 50    ' # 只看守护进程日志；server 同理
su -c 'sh /data/adb/agent2api/bin/a2a update         ' # 按 update_channel 在线升级（默认 beta）
su -c 'sh /data/adb/agent2api/bin/a2a update --beta  ' # 含预发布版
su -c 'sh /data/adb/agent2api/bin/a2a update --force ' # 同版本也重装（版本混乱时用）
su -c 'sh /data/adb/agent2api/bin/a2a rollback       ' # 回滚到升级前的版本
su -c 'sh /data/adb/agent2api/bin/a2a dns show       ' # 当前写的 DNS
su -c 'sh /data/adb/agent2api/bin/a2a dns refresh    ' # 立刻重新抓取并重写
su -c 'sh /data/adb/agent2api/bin/a2a dns probe      ' # 实测解析（baidu + github）
su -c 'sh /data/adb/agent2api/bin/a2a url            ' # 打印面板地址
su -c 'sh /data/adb/agent2api/bin/a2a config         ' # 打印生效配置
su -c 'sh /data/adb/agent2api/bin/a2a version        ' # 模块版本 / 载荷版本
```

---

## 5. 配置

文件：`/data/adb/agent2api/etc/settings.conf`（首次安装自动生成，权限 600）
改完执行 `su -c 'sh /data/adb/agent2api/bin/a2a restart`。守护进程每轮循环都会重读，改门限类参数甚至不用重启。

常用几项：

| 键 | 默认 | 说明 |
|---|---|---|
| `autostart` | 1 | 开机自启 |
| `watchdog` | 1 | 崩溃自动拉起 |
| `port` | 3065 | 服务端口 |
| `host` | 127.0.0.1 | 新装默认仅本机；完成首注册后可改 `0.0.0.0` 开放 LAN（旧配置升级保留） |
| `oom_protect` | 0 | 写 `oom_score_adj=-900`，抗 lmkd（极端内存压力下可能拖累系统，谨慎） |
| `keep_awake` | 0 | 常驻唤醒锁（费电） |
| `wifi_only` | 0 | 只在 Wi-Fi 下运行 |
| `battery_floor` | 0 | 低于 N% 且未充电自动停服 |
| `dns_mode` | auto | `auto`/`system`/`static`/`off` |
| `ipv4_preferred` | 1 | 优先 IPv4（关掉可能在双栈网络下超时） |
| `update_channel` | beta | `stable`/`beta` |
| `github_mirror` | 空 | 例 `https://ghfast.top/`，国内升级用 |
| `purge_on_uninstall` | 0 | 卸载时连数据一起删 |

---

## 6. 在线升级（两条线）

**A. 载荷升级（服务端本体）：`a2a update`**

```
查最新 tag（beta 按版本号取最大规范 release，stable 取 releases/latest）
  → 下载 agent2api-server-linux-arm64.tar.gz（可走 github_mirror）
  → 官方 .sha256 始终直连 GitHub；可选 update_pin 独立固定摘要；不匹配就中止
  → tar 路径/链接安全检查 → 解包 → 校验 ELF/aarch64/ui → 复用现有 lib（或新包自带）
  → payload_install_from（先写 .new、二次校验、三段式 rename）
  → 按更新前运行状态重启 + HTTP 健康检查 → 失败自动回滚并强制重启
```

**B. 模块升级（脚本/服务文件）：Magisk 的 `updateJson`**

想让"模块本身"也能收到更新通知，把 `module.prop` 里的 `updateJson=` 指向你自己托管的 JSON
（格式见 `docs/update.json.example`），里面 `zipUrl` 指向新模块 zip、`versionCode` 递增即可。
本模块交付时**故意留空**——挂一个不存在的地址只会让 Magisk 每次检查都报错。

> 为什么不做应用内一键升级：见风险表第 15 条。loader 直启会让 `current_exe` 指向 `ld.so`，
> 让上游自己去替换二进制等于自己把自己拆了。`a2a update` 做的是同一件事，但多了校验和回滚。

---

## 7. 目录与清理

```sh
# 看占用
du -sh /data/adb/agent2api/{payload,data,logs,backup,download}

# 清下载缓存与回滚备份（不影响运行）
rm -rf /data/adb/agent2api/download/* /data/adb/agent2api/backup/prev*

# 完全卸载（Magisk 里卸载模块后）
rm -rf /data/adb/agent2api
```

模块从不修改或挂载 `/system`；卸载后只清理自己的进程、运行状态与 `/data/a2a`。

---

## 8. 故障排查

| 现象 | 先看 | 处理 |
|---|---|---|
| 面板打不开 | `a2a status`、`a2a logs sup` | 服务端没起来 → `a2a doctor` |
| 日志里 `No such file or directory` 且没有更多信息 | `a2a doctor` 的 loader 项 | loader 跑不起来 = 内核/架构问题，换 arm64 机器或看 avc 日志 |
| 日志里 `Address already in use` | `a2a doctor` 的端口项 | 占用者 PID 会打出来，`kill` 掉或改 `port` |
| 域名解析失败 / 签到全红 | `a2a dns show`、`a2a dns probe` | `a2a dns refresh`；必要时 `dns_mode=static` + 写死的 DNS |
| 升级后起不来 | `a2a logs` | `a2a rollback` 立刻回到上一版 |
| 熄屏一会儿就断 | `a2a status` 的 restarts | 开 `keep_awake=1`，并把系统"电池优化"里对本模块无关（root 进程不走那套），主要看 OEM 的"后台冻结"是否按进程名生效 |
| 卸载后端口还被占 | `ps -A \| grep -i agent2api` | 手动 `kill`，或重启；正常情况 `uninstall.sh` 已经清了 |

收集一份完整报告给我：

```sh
su -c 'sh /data/adb/agent2api/bin/a2a doctor; echo ---; sh /data/adb/agent2api/bin/a2a status; echo ---; tail -n 80 /data/adb/agent2api/logs/server.log'
```

---

## 9. 已知限制

- **只支持 arm64**（上游只发 arm64/aarch64 二进制）。
- 用 `ld.so` 直启，所以 `ps` 里进程名是 `ld-linux-aarch64`，`argv0` 已设为 `agent2api-server` 方便识别。
- 应用内自更新被强制关闭（原因见风险表第 15 条），升级请用 `a2a update`。
- 新装默认监听 `127.0.0.1`；旧配置升级仍保留原 `host`。完成本机首注册后再按需开放 LAN。
- glibc 仍不经过 Android `netd`/Private DNS；VPN 私有域名或仅接受 DoT/DoH 的 DNS 主机名需手工 `dns_mode=static` 填可达服务器，并在 VPN/蜂窝网络切换后用 `a2a dns probe` 验证。
- VPN 出口时只采用隧道自己暴露的解析器（`dumpsys dnsresolver` 里 NetId 与 `tun*` 匹配的块），不会回退到底层 Wi-Fi/蜂窝的 DNS，避免查询走直连路由泄漏；若隧道不暴露任何解析器，则用 `dns_static`（默认 `223.5.5.5 119.29.29.29`）经隧道转发。
- root 进程没有应用包级 Doze 白名单；`keep_awake=0` 时深度睡眠仍可能暂停 CPU/网络。
- 没有做开机自启的"延迟到解锁后"逻辑（FBE 设备上 `/data/adb` 在 post-fs-data 阶段已可用，不需要）。

---

## 10. 打包信息

- 载荷来源：[84593320z/agent2api-musl](https://github.com/84593320z/agent2api-musl) CI 按上游 `v3.4.0` tag
  构建的 musl 静态 arm64 包（无 `PT_INTERP`，`/etc/resolv.conf` 已等长改写为 `/data/a2a/resolv`）
- glibc 运行时（`seed/lib/`）：Debian bookworm `libc6 2.36-9+deb12u14` + `libgcc-s1 12.2.0-14+deb12u1`（arm64），
  为在线升级到上游 glibc 包的动态载荷路径保留（二进制最高要求 `GLIBC_2.34`，2.36 完整覆盖）
- 下载器：静态链接的 `curl 8.23.0`（aarch64, musl），不依赖系统 CA 与 bionic
- CA：curl.se 官方 `cacert.pem`

产物（每次构建都会重新算，实际值看同目录的 `.zip.sha256`）：

```
dist/agent2api-magisk-v3.4.0-magisk.34.zip    约 30 MB（musl 静态载荷 + 完整 IANA zoneinfo）
```

刷之前想先核对一下的话（手机端或电脑端都行）：

```sh
sha256sum agent2api-magisk-v3.4.0-magisk.34.zip
cat    agent2api-magisk-v3.4.0-magisk.34.zip.sha256
```

---

## 11. 这份东西是怎么验过的

本机没有 arm64 环境（也没有 qemu），所以验证分两层：

1. **静态**：Android 入口/库脚本通过 `bash -n` 与 `dash -n`；检查无 CRLF、ZIP 路径安全、Unix 权限、ELF aarch64 和 glibc/curl 私有路径补丁。
2. **离线回归**：`tests/run-all.sh` 覆盖卸载固定路径/缺库中止、热安装脱钩、PID starttime、端口归属、健康响应体、DNS 失败保留、日志 copytruncate、非 arm64 插件不变、版本排序和时区缺失 fail-closed；Python 另外解析 TZif 验证纽约 EST/EDT 与上海 UTC+8。
3. **构建验收**：`verify_package.py <zip>` 对显式产物校验 SHA-256、CRC、结构、权限、脚本和时区数据。

离线测试跑在 MSYS 的 GNU coreutils/sed 上，和 Android 的 toybox 不是一套实现，所以下面四类差异必须单独卡（`tests/run-static.sh` 已逐条断言，不靠人记）：

- **换行**：`/system/bin/sh` 把 CRLF 里的 `\r` 当普通字符，`case x in\r` 直接报 `Syntax error: word unexpected (expecting "in")`，一个脚本被 Windows 工具回写成 CRLF 就能让整个模块起不来。构建与回归逐字节确认所有脚本是纯 LF。
- **sed**：toybox 的 sed 是 POSIX BRE，不认 GNU 的 `\+`。`s/^nameserver[[:space:]]\+\([0-9.]*\)/\1/p` 在电脑上能出结果、在手机上静默输出空串，这是"本地全绿、真机不对"的经典坑。源码层禁止 `\+`、`sed -i`、`sed -r/-E`。
- **参数展开里的 `|` 和 `(`**：Android 的 `/system/bin/sh` 是 mksh R59，`${x%%|*}` 里裸的 `|` 会被当成管道，展开结果直接是空串（`a2a status` 的 `DNS: 配置= 系统实际=` 后面全空就是这么来的）；`${x%%(*}` 更狠，直接 `no closing quote`。所有模式位置的分隔符必须转义成 `${x%%\|*}`，这种写法在 mksh、dash、bash 上行为一致。本机 bash 不报错，只能靠静态断言加真机跑套件卡住。
- **变量定义位置**：`dns.sh` 被 `post-fs-data.sh`、`supervise.sh`、`a2a` 三处 source，任何只属于 DNS 的路径变量都必须定义在 `common.sh`，否则在其中一处就是空串（`DNS_CACHE` 曾经整份源码都没赋值，`dns_write` 恒失败、`a2a status` 的 DNS 字段恒为空）。

正因为本机与真机的 shell 实现不同，`tests/run-all.sh` 设计成能在真机上直接跑（不需要 bash、不需要 python3）：

```sh
adb push tests /data/local/tmp/a2atest/tests
adb shell 'su 0 sh -c "cd /data/local/tmp/a2atest && TMPDIR=/data/local/tmp/a2atest/tmp sh tests/run-all.sh"'
```

在设备上跑的时候解析器就是真机 mksh 本体，`STATIC 11 / FUNCTIONAL 9 / SAFETY 6` 全绿才算通过；Python 那两项（TZif 解析、`py_compile`）会打印 `PYTHON SKIP`，因为设备上没有 python3，这两项在本机构建时已经跑过。

真机上唯一没法本地替代的就是"aarch64 二进制能不能在这台机器的内核上跑起来"——所以装完第一件事：

```sh
su -c 'sh /data/adb/agent2api/bin/a2a doctor'
```

---

## 12. magisk.16 改了什么（本版补丁包）

本版是社区补丁版（版本号 `v3.3.0-beta.6 (magisk.16)`，`versionCode 2026110116`），
在不改上游二进制、不动在线升级链路的前提下，修了"不挂 VPN 就用不了"这个根问题：

| 方向 | 改动 | 位置 |
|---|---|---|
| DNS | 采样分级兜底 + 每级写完立刻验活（探测 204），通了即停并记住；四级全失败则原样保留旧配置 | `libexec/dns.sh` 的 `dns_ensure()` / `dns_apply_list()` / `dns_static_list()` / `dns_liveness_ok()` |
| DNS | 全链接受 IPv6（nameserver 抽取、可用性判断、静态兜底都带 v6），并按本机地址家族排序 | `libexec/dns.sh` |
| DNS | 未变化时按 `dns_verify_interval`（默认 600 秒）抽检，解析坏了自动重写 | `libexec/dns.sh` |
| DNS | `post-fs-data` 的 bootstrap 不再写死 223.5.5.5，改读 `dns_static` / `dns_static_v6` | `post-fs-data.sh` |
| 启动 | `net_ready()` 改三级判据（`ip route get` + 全表默认路由 + 有全局地址），不再因为 main 表空就空等 45 秒 | `libexec/common.sh` |
| 启动 | `wait_net` 超时不再静默，写一行日志后按无网继续 | `service.sh` |
| 启动 | 时区初始化失败只告警，不再 `exit 1` 拖死服务 | `libexec/launch.sh` |
| 守护 | 主循环每轮重读端口配置，改端口后"占用判断"和"健康检查"不再各看一个 | `libexec/supervise.sh` |
| 事务 | 残留载荷清理挪到取得更新锁之后（原来会误删并发事务刚建好的目录） | `customize.sh` |
| 事务 | 安装成功前 `sync`，断电不会留半份模块 | `customize.sh` |
| 事务 | 软链刷新失败不再判定"载荷切换失败"（避免回滚一份已经落好的新载荷） | `libexec/payload.sh` |
| 升级 | `api.github.com` 直连失败时，可用 `github_mirror` 再拉一次版本列表；包体与 sha256 仍强制官方 | `libexec/updater.sh` |
| 体验 | 卡片描述实时显示状态/端口/载荷/面板；`action.sh` 变成"一键开面板" | `libexec/common.sh`、`libexec/supervise.sh`、`action.sh` |
| 体验 | `webroot/status.json` + `lastlog.txt`，看板页 5 秒刷新，不需要 `ksu.exec` | `libexec/supervise.sh`、`webroot/index.html` |
| 体检 | `a2a status` 的时区不再恒显示"跟随系统" | `libexec/a2a` |
| 性能 | 日志轮转只搬尾部（`tail -c`），不再整份复制 8MB | `libexec/common.sh` |
| 性能 | 插件解释器扫描改 `find -maxdepth 3`，并保留原权限位 | `libexec/plugin.sh` |

新增配置项（写在 `settings.conf` 里即可）：`dns_verify_interval`、`dns_probe`、`dns_probe_url`、
`dns_static_v6`、`update_mirror_api`、`dynamic_desc`。详见 `docs/CHANGELOG-magisk.15.md`。

> 注：第 11 节提到的 `tests/` 目录属于上游源码仓库，模块安装包里本来就不带，
> 所以那几条命令要在源码目录里跑，别在手机模块目录里找。
